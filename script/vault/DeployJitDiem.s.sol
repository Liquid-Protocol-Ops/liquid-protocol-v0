// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IInferenceVaultQueue} from "../../src/vault/interfaces/IInferenceVaultQueue.sol";
import {jitDIEM} from "../../src/vault/jitDIEM.sol";
import {IFeeLockerClaim, jitDIEMFeeConverter} from "../../src/vault/jitDIEMFeeConverter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Script, console} from "forge-std/Script.sol";

/// Deploys jitDIEM (vault + v4 hook) and jitDIEMFeeConverter, initializes the DIEM/wstDIEM pool
/// at NAV, seeds dead shares, and hands ownership to the Safe (which must call acceptOwnership).
///
/// foundry.toml compiles jitDIEM at 200 optimizer runs (it exceeds EIP-170 at 20k). Deploy:
///   forge script script/vault/DeployJitDiem.s.sol \
///     --rpc-url "$BASE_RPC_URL" --private-key "$DEPLOYER_PK" --broadcast --verify
/// The deployer must hold JIT_SEED DIEM (default 0.01) for the dead-share seed.
contract DeployJitDiem is Script {
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant WSTDIEM = 0xe49FA849cB37b0e7A42B2335e333fb99474167ba; // InferenceVault v6
    address constant FEE_LOCKER = 0xF7d3BE3FC0de76fA5550C29A8F6fa53667B876FF; // LiquidFeeLocker
    address constant SAFE = 0x872c561f699B42977c093F0eD8b4C9a431280c6c;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function params() internal pure returns (jitDIEM.Params memory) {
        return jitDIEM.Params({
            minSellFeeBps: 100, // 1%
            maxSellFeeBps: 500, // 5%
            buyInventoryFeeBps: 5, // 0.05%, matches the wstDIEM deposit fee
            targetIdleBps: 5000, // 50% idle DIEM
            floorIdleBps: 500, // sells revert below 5% idle
            rebalanceBandBps: 1000,
            exitFeeBps: 10, // 0.1%
            maxNavDropBps: 100, // 1% NAV drop trips the sell breaker
            maxNavGrowthBpsPerYear: 5000,
            rewardVestingPeriod: 3 days,
            maintainInterval: 1 hours,
            navGrowthWindow: 1 days,
            autoMaintain: true
        });
    }

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(pk);
        uint256 seed = vm.envOr("JIT_SEED", uint256(1e16));
        IInferenceVaultQueue wst = IInferenceVaultQueue(WSTDIEM);
        IERC20 diem = IERC20(wst.asset());

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        ); // 0x28C8
        bytes memory args = abi.encode(IPoolManager(POOL_MANAGER), wst, deployer, params());
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(jitDIEM).creationCode, args);
        console.log("Mined jitDIEM address:", expected);

        // Pool price = currency1 per currency0, set at NAV (the curve is never used; this is display only).
        uint256 nav = wst.convertToAssets(1e18);
        bool diemIs0 = address(diem) < WSTDIEM;
        uint256 priceWad = diemIs0 ? 1e36 / nav : nav;
        uint160 sqrtPriceX96 = uint160(Math.sqrt(Math.mulDiv(priceWad, 2 ** 192, 1e18)));
        (address c0, address c1) = diemIs0 ? (address(diem), WSTDIEM) : (WSTDIEM, address(diem));

        vm.startBroadcast(pk);
        jitDIEM jit = new jitDIEM{salt: salt}(IPoolManager(POOL_MANAGER), wst, deployer, params());
        require(address(jit) == expected, "hook address mismatch");
        require(address(jit).code.length <= 24_576, "jitDIEM over EIP-170");

        IPoolManager(POOL_MANAGER)
            .initialize(
                PoolKey(Currency.wrap(c0), Currency.wrap(c1), 0, 1, IHooks(address(jit))),
                sqrtPriceX96
            );

        // Dead shares close the first-depositor inflation window.
        diem.approve(address(jit), seed);
        jit.deposit(seed, DEAD);

        jitDIEMFeeConverter converter =
            new jitDIEMFeeConverter(wst, address(jit), IFeeLockerClaim(FEE_LOCKER));

        jit.transferOwnership(SAFE); // Ownable2Step: Safe must call acceptOwnership()
        vm.stopBroadcast();

        console.log("jitDIEM:", address(jit));
        console.log("jitDIEMFeeConverter:", address(converter));
        console.log("Next: Safe calls jitDIEM.acceptOwnership() and setGuardian(<keeper>).");
        console.log(
            "Next: on wstDIEM-paired launches, add the converter as a reward recipient with FeeIn.Paired."
        );
    }
}
