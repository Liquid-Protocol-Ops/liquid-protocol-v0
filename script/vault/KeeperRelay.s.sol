// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

// KeeperRelay — the wstdiem-keeper's per-cycle relay for inference yield.
//
// Yield flow (relay model): AntSeed / Surplus settle inference USDC to the keeper EOA
// (0x988CE72d). Each cycle the keeper pushes that USDC into a registered adapter and routes it:
//   keeper USDC --approve--> adapter --receiveSettlement--> adapter holds USDC
//   adapter.routeYield(minDiemOut): USDC -> WETH -> DIEM (V3, reverts below minDiemOut), then
//     90% -> vault.creditDIEM()    (raises wstDIEM rate for ALL holders = yield)
//     10% -> vault.creditWstDIEM() (operator cut, compounds to the adapter)
//
// The keeper attributes commingled USDC off-chain (it knows which venue paid how much) and
// calls this per adapter so per-venue operator-fee wstDIEM accrues to the right adapter.
//
// MIN_DIEM_OUT (MOG-541): the keeper must quote USDC->WETH->DIEM off-chain and pass a floor
// net of acceptable slippage. It is REQUIRED (no default) so a swap can never settle at full
// slippage; a misconfigured cron reverts rather than routing into a sandwich.
//
// v6 adapters:  AntSeed 0xed98A5f4F3AcFd0752A81FDd03DD28b7A44A18b7
//               Surplus 0x91b3E39Ef6335D97876AdB4448A998c7cbD3885F
//
// Run (cron this; keeper key from ~/.splits/config.json):
//   ADAPTER=<adapter> MIN_DIEM_OUT=<diem 18dec floor> \
//   [AMOUNT=<usdc 6dec, 0/unset = full keeper balance>] KEEPER_PK=<pk> \
//   forge script script/vault/KeeperRelay.s.sol --tc KeeperRelay --rpc-url $BASE_RPC_URL --broadcast
//
// Dry-run: drop --broadcast. Reverts harmlessly with "no USDC" when there's nothing to route,
// so it is safe to schedule on a tight interval.

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
}

interface IInferenceAdapter {
    function receiveSettlement(uint256 usdcAmount) external;
    function routeYield(uint256 minDiemOut) external;
    function vault() external view returns (address);
    function usdc() external view returns (address);
}

contract KeeperRelay is Script {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        address adapter = vm.envAddress("ADAPTER");
        uint256 pk = vm.envUint("KEEPER_PK");
        address keeper = vm.addr(pk);

        // Sanity: the adapter must be a USDC adapter (catches a wrong address before broadcast).
        require(IInferenceAdapter(adapter).usdc() == USDC, "adapter usdc mismatch");

        uint256 bal = IERC20(USDC).balanceOf(keeper);
        uint256 amount = vm.envOr("AMOUNT", uint256(0));
        if (amount == 0) amount = bal;
        require(amount > 0, "no USDC to relay");
        require(amount <= bal, "AMOUNT exceeds keeper USDC balance");

        // MOG-541: required off-chain slippage floor for the USDC->WETH->DIEM swap.
        uint256 minDiemOut = vm.envUint("MIN_DIEM_OUT");

        vm.startBroadcast(pk);
        // Push keeper USDC into the adapter, then route it to DIEM/creditDIEM.
        if (IERC20(USDC).allowance(keeper, adapter) < amount) {
            IERC20(USDC).approve(adapter, amount);
        }
        IInferenceAdapter(adapter).receiveSettlement(amount);
        IInferenceAdapter(adapter).routeYield(minDiemOut);
        vm.stopBroadcast();

        console.log("relayed USDC (6dec):", amount);
        console.log("adapter:", adapter);
        console.log("vault credited:", IInferenceAdapter(adapter).vault());
    }
}
