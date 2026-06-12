// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IInferenceVault} from "./interfaces/IInferenceVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ── Morpho Blue interfaces ────────────────────────────────────────────────────

/// @dev Five-field struct required by every Morpho Blue market call.
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

interface IMorpho {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
    function supplyCollateral(
        MarketParams calldata params,
        uint256 assets,
        address onBehalf,
        bytes calldata data
    ) external;
    function borrow(
        MarketParams calldata params,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256);
    function repay(
        MarketParams calldata params,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256);
    function withdrawCollateral(
        MarketParams calldata params,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external;
}

interface IMorphoFlashLoanCallback {
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}

/// @dev Curve StableSwap — synchronous wstDIEM→DIEM exit path.
///      Coin indices: 0=DIEM, 1=wstDIEM. Used by unloopDeposit because
///      vault.redeem() requires the async redeem queue in production (~2 days;
///      not a 14-day timelock — that was the old v4 vault).
interface ICurveStableSwap {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}

enum LeverageAction {
    LOOP,
    UNLOOP
}
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IVVVStaking {
    function stake(address to, uint256 vvvAmount) external;
    // mintDiem returns void — measure output via balance delta.
    function mintDiem(uint256 sVVVAmount, uint256 minDiemOut) external;
    function burnDiem(uint256 diemAmount) external;
}

interface ISwapRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut);
}

contract Router is Ownable, ReentrancyGuard, IMorphoFlashLoanCallback {
    using SafeERC20 for IERC20;

    uint256 constant WAD = 1e18;

    // Uniswap V3 SwapRouter02 on Base
    address constant V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    // WETH/DIEM V3 pool fee tier. Default 1%. Owner-updatable.
    uint24 public diemV3Fee = 10_000;
    // V4 wstDIEM/WETH pool fee tier and tick spacing. Owner-updatable (must be set together).
    uint24 public wstDiemV4Fee = 3000;
    int24 public wstDiemV4TickSpacing = 60;
    // V4 wstDIEM/WETH pool hook address. address(0) = no hook. Owner-updatable.
    address public wstDiemV4Hooks;
    uint160 constant MIN_SQRT_PRICE_PLUS_1 = 4_295_128_740; // TickMath.MIN_SQRT_PRICE + 1
    uint160 constant MAX_SQRT_PRICE_MINUS_1 =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    IInferenceVault public immutable vault;
    address public immutable weth;
    address public immutable vvv;
    address public immutable vvvStaking;
    // True when WETH address < vault address (WETH is currency0 in the V4 PoolKey).
    // Computed once at construction — determines swap direction in unlockCallback.
    bool public immutable wethIsCurrency0;

    address public v4Pool; // V4 PoolManager address (required for exitToWETH)

    // ── Leverage state ────────────────────────────────────────────────────────
    address public immutable morpho; // Morpho Blue on Base
    address public curvePool; // Curve DIEM/wstDIEM StableSwap
    MarketParams public leverageMarketParams;
    // Transient: caller address while a flash loan is in flight; guards onMorphoFlashLoan.
    address private _flashLoanCaller;
    // Written by _executeUnloop inside the callback, read by unloopDeposit after.
    uint256 private _unloopNetDiem;

    error PoolNotSet();
    error SlippageExceeded();
    error ZeroAddress();
    error OnlyPoolManager();
    error OnlyMorpho();
    error UnexpectedCallback();
    error LtvTooHigh();
    error MarketNotSet();

    event LeverageMarketSet(
        address loanToken, address collateralToken, address oracle, address irm, uint256 lltv
    );
    event LoopDeposit(
        address indexed caller, uint256 diemIn, uint256 flashAmount, uint256 totalWst
    );
    event UnloopDeposit(address indexed caller, uint256 wstAmount, uint256 netDiem);
    event SwapFeesSet(
        uint24 diemV3Fee, uint24 wstDiemV4Fee, int24 wstDiemV4TickSpacing, address wstDiemV4Hooks
    );

    /// @param _morpho Morpho Blue address. Pass address(0) to use the Base mainnet
    ///                default (0xBBBBBbbBBb...). Explicit injection enables unit tests
    ///                to use MockMorpho without forking.
    constructor(
        address _vault,
        address _weth,
        address _vvv,
        address _vvvStaking,
        address _morpho,
        address initialOwner
    ) Ownable(initialOwner) {
        if (
            _vault == address(0) || _weth == address(0) || _vvv == address(0)
                || _vvvStaking == address(0)
        ) {
            revert ZeroAddress();
        }
        vault = IInferenceVault(_vault);
        weth = _weth;
        vvv = _vvv;
        vvvStaking = _vvvStaking;
        wethIsCurrency0 = uint160(_weth) < uint160(_vault);
        morpho = _morpho != address(0) ? _morpho : 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    }

    // WETH → DIEM (V3 1% pool) → vault.deposit → wstDIEM
    function depositWETH(uint256 wethAmount, uint256 minWstDIEM, address receiver)
        external
        returns (uint256 shares)
    {
        // Note: v4Pool is only required for exitToWETH, not for this deposit path.
        address diem = vault.asset();

        IERC20(weth).safeTransferFrom(msg.sender, address(this), wethAmount);
        IERC20(weth).approve(V3_ROUTER, wethAmount);

        uint256 diemOut = ISwapRouterV3(V3_ROUTER)
            .exactInputSingle(
                ISwapRouterV3.ExactInputSingleParams({
                    tokenIn: weth,
                    tokenOut: diem,
                    fee: diemV3Fee,
                    recipient: address(this),
                    amountIn: wethAmount,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );

        IERC20(diem).approve(address(vault), diemOut);
        shares = vault.deposit(diemOut, receiver);
        if (shares < minWstDIEM) revert SlippageExceeded();
    }

    // wstDIEM → WETH via V4 wstDIEM/WETH secondary market pool
    function exitToWETH(uint256 wstDIEMAmount, uint256 minWETH, address receiver)
        external
        returns (uint256 wethOut)
    {
        if (v4Pool == address(0)) revert PoolNotSet();
        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), wstDIEMAmount);

        bytes memory result =
            IPoolManager(v4Pool).unlock(abi.encode(wstDIEMAmount, minWETH, receiver));
        wethOut = abi.decode(result, (uint256));
    }

    // V4 unlock callback — executes wstDIEM → WETH swap inside PoolManager context.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != v4Pool) revert OnlyPoolManager();

        (uint256 wstDIEMAmount, uint256 minWETH, address receiver) =
            abi.decode(data, (uint256, uint256, address));

        // PoolKey ordering depends on address comparison (V4 requires currency0 < currency1).
        // wethIsCurrency0 is computed once at construction.
        (address c0, address c1) = wethIsCurrency0 ? (weth, address(vault)) : (address(vault), weth);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: wstDiemV4Fee,
            tickSpacing: wstDiemV4TickSpacing,
            hooks: IHooks(wstDiemV4Hooks)
        });

        // Selling wstDIEM for WETH:
        // If WETH=c0: zeroForOne=false (c1→c0), WETH returned as delta.amount0()
        // If WETH=c1: zeroForOne=true  (c0→c1), WETH returned as delta.amount1()
        bool zeroForOne = !wethIsCurrency0; // selling wstDIEM, which is whichever currency is NOT WETH
        BalanceDelta delta = IPoolManager(v4Pool)
            .swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(wstDIEMAmount),
                    sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_PLUS_1 : MAX_SQRT_PRICE_MINUS_1
                }),
                ""
            );

        uint256 wethReceived =
            wethIsCurrency0 ? uint256(int256(delta.amount0())) : uint256(int256(delta.amount1()));
        if (wethReceived < minWETH) revert SlippageExceeded();

        // Settle: pay wstDIEM to PoolManager
        IPoolManager(v4Pool).sync(Currency.wrap(address(vault)));
        IERC20(address(vault)).transfer(v4Pool, wstDIEMAmount);
        IPoolManager(v4Pool).settle();

        // Take WETH from PoolManager to receiver
        IPoolManager(v4Pool).take(Currency.wrap(weth), receiver, wethReceived);

        return abi.encode(wethReceived);
    }

    // VVV → sVVV → DIEM → wstDIEM
    function depositVVV(uint256 vvvAmount, uint256 minWstDIEM, address receiver)
        external
        returns (uint256 shares)
    {
        address diem = vault.asset();
        IERC20(vvv).safeTransferFrom(msg.sender, address(this), vvvAmount);
        IERC20(vvv).approve(vvvStaking, vvvAmount);
        IVVVStaking(vvvStaking).stake(address(this), vvvAmount);

        uint256 diemBefore = IERC20(diem).balanceOf(address(this));
        uint256 sVVV = IERC20(vvvStaking).balanceOf(address(this));
        IVVVStaking(vvvStaking).mintDiem(sVVV, 0);
        uint256 diemMinted = IERC20(diem).balanceOf(address(this)) - diemBefore;

        IERC20(diem).approve(address(vault), diemMinted);
        shares = vault.deposit(diemMinted, receiver);
        if (shares < minWstDIEM) revert SlippageExceeded();
    }

    // Admin
    function setV4Pool(address _pool) external onlyOwner {
        v4Pool = _pool;
    }

    // ── Morpho leverage: loop ─────────────────────────────────────────────────

    /// @notice Open a leveraged wstDIEM position in a single tx via Morpho flash loan.
    ///
    ///   Equity: caller deposits `diemAmount` DIEM.
    ///   Flash:  router borrows `flashAmount` DIEM (free, Morpho Blue).
    ///   Result: total DIEM deposited into vault → wstDIEM → Morpho collateral (caller owned).
    ///           Caller's Morpho debt = flashAmount DIEM.
    ///
    ///   Pre-condition: IMorpho(morpho).setAuthorization(address(router), true)
    ///
    /// @param diemAmount  Equity DIEM pulled from caller.
    /// @param targetLTV   Desired LTV in WAD (e.g. 0.70e18). Must be < market LLTV − 100 bps.
    /// @param minWstOut   Minimum wstDIEM collateral (slippage guard — vault fee reduces output).
    function loopDeposit(uint256 diemAmount, uint256 targetLTV, uint256 minWstOut)
        external
        nonReentrant
        returns (uint256 totalWst)
    {
        MarketParams memory params = leverageMarketParams;
        if (params.loanToken == address(0)) revert MarketNotSet();
        // Headroom must exceed the vault deposit fee so the post-fee collateral
        // value keeps the position safely below LLTV.
        uint256 feeBps = vault.currentDepositFeeBps();
        if (targetLTV + feeBps * 1e18 / 10_000 >= params.lltv) revert LtvTooHigh();

        address diem = vault.asset();
        IERC20(diem).safeTransferFrom(msg.sender, address(this), diemAmount);

        uint256 totalDiem = diemAmount * WAD / (WAD - targetLTV);
        uint256 flashAmount = totalDiem - diemAmount;

        _flashLoanCaller = msg.sender;
        IMorpho(morpho)
            .flashLoan(
                diem,
                flashAmount,
                abi.encode(LeverageAction.LOOP, msg.sender, diemAmount, flashAmount, minWstOut)
            );
        _flashLoanCaller = address(0);

        totalWst = vault.previewDeposit(totalDiem);
        emit LoopDeposit(msg.sender, diemAmount, flashAmount, totalWst);
    }

    /// @notice Unwind a leveraged wstDIEM position in a single tx via Morpho flash loan.
    ///
    ///   Flash:  borrow `borrowRepay` DIEM → repay caller's Morpho debt.
    ///   Withdraw caller's wstDIEM collateral → swap to DIEM via Curve.
    ///   Net DIEM (Curve output − borrowRepay) sent to caller.
    ///
    ///   Pre-condition: IMorpho(morpho).setAuthorization(address(router), true)
    ///
    /// @param wstAmount   wstDIEM collateral to withdraw from caller's Morpho position.
    /// @param borrowRepay Exact DIEM debt to repay (read from Morpho off-chain).
    /// @param minDiemOut  Minimum net DIEM after repaying flash loan (Curve slippage guard).
    function unloopDeposit(uint256 wstAmount, uint256 borrowRepay, uint256 minDiemOut)
        external
        nonReentrant
        returns (uint256 netDiem)
    {
        if (curvePool == address(0)) revert PoolNotSet();
        MarketParams memory params = leverageMarketParams;
        if (params.loanToken == address(0)) revert MarketNotSet();

        address diem = vault.asset();
        _flashLoanCaller = msg.sender;
        IMorpho(morpho)
            .flashLoan(
                diem,
                borrowRepay,
                abi.encode(LeverageAction.UNLOOP, msg.sender, wstAmount, borrowRepay, minDiemOut)
            );
        _flashLoanCaller = address(0);

        netDiem = _unloopNetDiem;
        _unloopNetDiem = 0;
        emit UnloopDeposit(msg.sender, wstAmount, netDiem);
    }

    /// @notice Morpho flash-loan callback. NOT nonReentrant — OZ counter already
    ///         locked by the calling function; msg.sender==morpho guard blocks others.
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external override {
        if (msg.sender != morpho) revert OnlyMorpho();
        if (_flashLoanCaller == address(0)) revert UnexpectedCallback();

        (LeverageAction action, address caller, uint256 arg1, uint256 arg2, uint256 arg3) =
            abi.decode(data, (LeverageAction, address, uint256, uint256, uint256));

        if (action == LeverageAction.LOOP) {
            _executeLoop(caller, arg1, arg2, arg3); // arg1=equity, arg2=flash, arg3=minWst
        } else {
            _executeUnloop(caller, arg1, arg2, arg3); // arg1=wstAmt, arg2=repay, arg3=minDiem
        }
        // Approve Morpho to pull flash-loan repayment before callback returns.
        IERC20(vault.asset()).approve(morpho, assets);
    }

    function _executeLoop(
        address caller,
        uint256 diemAmount,
        uint256 flashAmount,
        uint256 minWstOut
    ) internal {
        address diem = vault.asset();
        uint256 totalDiem = diemAmount + flashAmount;

        IERC20(diem).approve(address(vault), totalDiem);
        uint256 totalWst = vault.deposit(totalDiem, address(this));
        if (totalWst < minWstOut) revert SlippageExceeded();

        MarketParams memory params = leverageMarketParams;
        IERC20(address(vault)).approve(morpho, totalWst);
        IMorpho(morpho).supplyCollateral(params, totalWst, caller, "");
        IMorpho(morpho).borrow(params, flashAmount, 0, caller, address(this));
    }

    function _executeUnloop(
        address caller,
        uint256 wstAmount,
        uint256 borrowRepay,
        uint256 minDiemOut
    ) internal {
        address diem = vault.asset();
        MarketParams memory params = leverageMarketParams;

        IERC20(diem).approve(morpho, borrowRepay);
        IMorpho(morpho).repay(params, borrowRepay, 0, caller, "");
        IMorpho(morpho).withdrawCollateral(params, wstAmount, caller, address(this));

        // Swap wstDIEM → DIEM via Curve (coin 0=DIEM, 1=wstDIEM).
        IERC20(address(vault)).approve(curvePool, wstAmount);
        uint256 diemReceived = ICurveStableSwap(curvePool).exchange(1, 0, wstAmount, 0);

        if (diemReceived < borrowRepay) revert SlippageExceeded();
        uint256 netDiem = diemReceived - borrowRepay;
        if (netDiem < minDiemOut) revert SlippageExceeded();

        _unloopNetDiem = netDiem;
        IERC20(diem).safeTransfer(caller, netDiem);
    }

    function setSwapFees(
        uint24 _diemV3Fee,
        uint24 _wstDiemV4Fee,
        int24 _wstDiemV4TickSpacing,
        address _wstDiemV4Hooks
    ) external onlyOwner {
        require(_diemV3Fee > 0 && _diemV3Fee <= 10_000, "invalid DIEM V3 fee");
        bool isDynamic = _wstDiemV4Fee == LPFeeLibrary.DYNAMIC_FEE_FLAG;
        require(
            (_wstDiemV4Fee > 0 && _wstDiemV4Fee <= LPFeeLibrary.MAX_LP_FEE) || isDynamic,
            "invalid V4 fee"
        );
        require(_wstDiemV4TickSpacing > 0, "invalid tick spacing");
        diemV3Fee = _diemV3Fee;
        wstDiemV4Fee = _wstDiemV4Fee;
        wstDiemV4TickSpacing = _wstDiemV4TickSpacing;
        wstDiemV4Hooks = _wstDiemV4Hooks;
        emit SwapFeesSet(_diemV3Fee, _wstDiemV4Fee, _wstDiemV4TickSpacing, _wstDiemV4Hooks);
    }

    function setLeverageMarket(MarketParams calldata params) external onlyOwner {
        leverageMarketParams = params;
        emit LeverageMarketSet(
            params.loanToken, params.collateralToken, params.oracle, params.irm, params.lltv
        );
    }

    function setCurvePool(address _pool) external onlyOwner {
        curvePool = _pool;
    }
}
