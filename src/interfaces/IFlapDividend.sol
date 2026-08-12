// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Read-only interface to the Flap Tax Token V3 Dividend contract,
/// used in tracker-only mode (dividendBps == 0) as the canonical holder-share
/// registry for $ASS. Shares are maintained by the Flap token itself via
/// setShare() on every transfer; exclusions and the 10,000 $ASS minimum
/// (minimumShareBalance) are enforced on Flap's side.
/// Verified against deployed BNB mainnet Dividend ABI; re-validated end-to-end
/// in the Task 0 throwaway launch before mainnet reliance.
interface IFlapDividend {
    /// @return share            current eligible share (raw $ASS units; 0 if excluded/below minimum)
    /// @return rewardDebt       Flap-internal single-token accounting (unused by us)
    /// @return pendingBalance   Flap-internal pending payout (unused by us)
    function userInfo(address user)
        external
        view
        returns (uint256 share, uint256 rewardDebt, uint256 pendingBalance);

    /// @return total of all eligible shares — our reconciliation anchor
    function totalShares() external view returns (uint256);

    /// @return minimum $ASS balance for dividend eligibility (raw units)
    function minimumShareBalance() external view returns (uint256);

    function excludedFromDividends(address user) external view returns (bool);
}