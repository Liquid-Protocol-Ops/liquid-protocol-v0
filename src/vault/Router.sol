// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IInferenceVault} from "./interfaces/IInferenceVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

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
    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);
}

contract Router is Ownable {
    using SafeERC20 for IERC20;

    // Uniswap V3 SwapRouter02 on Base
    address constant V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    // WETH/DIEM V3 pool fee: 1%
    uint24 constant DIEM_V3_FEE = 10_000;
    // V4 wstDIEM/WETH pool params
    uint24 constant WSTDIEM_V4_FEE = 3_000;
    int24 constant WSTDIEM_V4_TICK_SPACING = 60;
    uint160 constant MIN_SQRT_PRICE_PLUS_1  = 4295128740;                              // TickMath.MIN_SQRT_PRICE + 1
    uint160 constant MAX_SQRT_PRICE_MINUS_1 = 1461446703485210103287273052203988822378723970341;

    IInferenceVault public immutable vault;
    address public immutable weth;
    address public immutable vvv;
    address public immutable vvvStaking;
    // True when WETH address < vault address (WETH is currency0 in the V4 PoolKey).
    // Computed once at construction — determines swap direction in unlockCallback.
    bool public immutable wethIsCurrency0;

    address public v4Pool;    // V4 PoolManager address (required for exitToWETH)

    error PoolNotSet();
    error SlippageExceeded();
    error ZeroAddress();
    error OnlyPoolManager();

    constructor(address _vault, address _weth, address _vvv, address _vvvStaking) Ownable(msg.sender) {
        if (_vault == address(0) || _weth == address(0) || _vvv == address(0) || _vvvStaking == address(0)) {
            revert ZeroAddress();
        }
        vault = IInferenceVault(_vault);
        weth = _weth;
        vvv = _vvv;
        vvvStaking = _vvvStaking;
        // Determine V4 PoolKey ordering at construction. V4 requires currency0 < currency1.
        // The vault address depends on deployer nonce and cannot be predicted ahead of time.
        wethIsCurrency0 = uint160(_weth) < uint160(_vault);
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

        uint256 diemOut = ISwapRouterV3(V3_ROUTER).exactInputSingle(
            ISwapRouterV3.ExactInputSingleParams({
                tokenIn:           weth,
                tokenOut:          diem,
                fee:               DIEM_V3_FEE,
                recipient:         address(this),
                amountIn:          wethAmount,
                amountOutMinimum:  0,
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

        bytes memory result = IPoolManager(v4Pool).unlock(
            abi.encode(wstDIEMAmount, minWETH, receiver)
        );
        wethOut = abi.decode(result, (uint256));
    }

    // V4 unlock callback — executes wstDIEM → WETH swap inside PoolManager context.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != v4Pool) revert OnlyPoolManager();

        (uint256 wstDIEMAmount, uint256 minWETH, address receiver) =
            abi.decode(data, (uint256, uint256, address));

        // PoolKey ordering depends on address comparison (V4 requires currency0 < currency1).
        // wethIsCurrency0 is computed once at construction.
        (address c0, address c1) = wethIsCurrency0
            ? (weth, address(vault))
            : (address(vault), weth);

        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(c0),
            currency1:   Currency.wrap(c1),
            fee:         WSTDIEM_V4_FEE,
            tickSpacing: WSTDIEM_V4_TICK_SPACING,
            hooks:       IHooks(address(0))
        });

        // Selling wstDIEM for WETH:
        // If WETH=c0: zeroForOne=false (c1→c0), WETH returned as delta.amount0()
        // If WETH=c1: zeroForOne=true  (c0→c1), WETH returned as delta.amount1()
        bool zeroForOne = !wethIsCurrency0; // selling wstDIEM, which is whichever currency is NOT WETH
        BalanceDelta delta = IPoolManager(v4Pool).swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne:        zeroForOne,
                amountSpecified:   -int256(wstDIEMAmount),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_PLUS_1 : MAX_SQRT_PRICE_MINUS_1
            }),
            ""
        );

        uint256 wethReceived = wethIsCurrency0
            ? uint256(int256(delta.amount0()))
            : uint256(int256(delta.amount1()));
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
}
