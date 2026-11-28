// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IInferenceVaultQueue} from "./interfaces/IInferenceVaultQueue.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IFeeLockerClaim {
    function availableFees(address feeOwner, address token) external view returns (uint256);
    function claim(address feeOwner, address token) external;
}

/// @title  jitDIEMFeeConverter
/// @notice Turns launch-pool fees into DIEM for jitDIEM.
///
///         Set this contract as a reward recipient (FeeIn.Paired) on wstDIEM-paired launches in
///         LiquidLpLockerFeeConversion. The locker then pays its whole share in wstDIEM (token-side
///         fees are swapped to wstDIEM in the launch pool). `convert()` claims that wstDIEM from
///         LiquidFeeLocker and redeems it through the wstDIEM vault queue with jitDIEM as the
///         receiver, so jitDIEM gets DIEM at NAV with no slippage. jitDIEM's `sync()` picks the DIEM
///         up and vests it to holders.
///
///         Fully permissionless and ownerless: nothing here can be redirected. Redeeming through
///         the queue (instead of selling wstDIEM into jitDIEM's own pool) is what makes the DIEM
///         new liquidity rather than a round trip.
///
///         The live vault gives every requestRedeem its own slot in a 50-slot batch, so this holds
///         at most one request in the open batch and adds to it only after that batch is flushed.
contract jitDIEMFeeConverter {
    using SafeERC20 for IERC20;

    IInferenceVaultQueue public immutable wst;
    IERC20 public immutable diem;
    address public immutable jitDIEM;
    IFeeLockerClaim public immutable feeLocker;

    uint256[] public requestIds;
    uint256 public claimHead;

    event Converted(uint256 indexed requestId, uint256 wstIn, uint256 diemOwed);
    event Claimed(uint256 indexed requestId, uint256 diem);
    event Forwarded(uint256 diem);

    constructor(IInferenceVaultQueue _wst, address _jitDIEM, IFeeLockerClaim _feeLocker) {
        wst = _wst;
        diem = IERC20(_wst.asset());
        jitDIEM = _jitDIEM;
        feeLocker = _feeLocker;
    }

    /// @notice Permissionless upkeep. Claims fees, claims settled redemptions (DIEM goes straight
    ///         to jitDIEM), forwards any stray DIEM, and queues held wstDIEM for redemption.
    /// @return requested wstDIEM queued in this call (0 if nothing was queued).
    function convert() external returns (uint256 requested) {
        if (feeLocker.availableFees(address(this), address(wst)) > 0) {
            feeLocker.claim(address(this), address(wst));
        }
        if (feeLocker.availableFees(address(this), address(diem)) > 0) {
            feeLocker.claim(address(this), address(diem));
        }
        claimSettled(10);

        uint256 d = diem.balanceOf(address(this));
        if (d > 0) {
            diem.safeTransfer(jitDIEM, d);
            emit Forwarded(d);
        }

        uint256 shares = wst.balanceOf(address(this));
        if (shares == 0 || shares < wst.minRedeemShares() || hasOpenRequest()) return 0;
        uint256 id = wst.requestRedeem(shares, jitDIEM);
        (, uint256 owed,,,,) = wst.requestStatus(id);
        requestIds.push(id);
        emit Converted(id, shares, owed);
        return shares;
    }

    /// @notice Claim up to `maxN` settled redemptions, oldest first. Anyone may call.
    function claimSettled(uint256 maxN) public {
        uint256 head = claimHead;
        uint256 end = requestIds.length;
        for (uint256 i; i < maxN && head < end; ++i) {
            uint256 id = requestIds[head];
            (, uint256 owed,,, bool settled, bool claimed) = wst.requestStatus(id);
            if (!claimed) {
                if (!settled) break;
                wst.claimRedeem(id);
                emit Claimed(id, owed);
            }
            ++head;
        }
        claimHead = head;
    }

    /// @notice True while this contract's latest request sits in a batch that has not been flushed.
    function hasOpenRequest() public view returns (bool) {
        uint256 n = requestIds.length;
        if (n == 0) return false;
        (,,, uint64 unlockAt,,) = wst.requestStatus(requestIds[n - 1]);
        return unlockAt == 0;
    }

    function pendingCount() external view returns (uint256) {
        return requestIds.length - claimHead;
    }
}
