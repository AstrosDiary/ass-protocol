// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title IPriceHub
 * @author Michael.W
 * @notice Interface for the PriceHub, supporting high-density batch price delivery
 * and optimized bit-packed storage access.
 */
interface IPriceHub {
    /**
     * @notice Snapshot of a price feed at a specific point in time.
     * @dev Fields are packed into specific bit-widths for storage efficiency:
     * @param price 18-decimal fixed-point aggregated price (80 bits).
     * @param aggregatedTs The timestamp of off-chain aggregation (48 bits).
     * @param onchainTs The timestamp when the price was mined on-chain (48 bits).
     */
    struct PriceSnapshot {
        uint80 price;
        uint48 aggregatedTs;
        uint48 onchainTs;
    }

    // --- Standard Interface (Decoded View) ---

    /**
     * @notice Returns a human-readable price snapshot for a specific feed.
     * @param feedId The 4-byte identifier.
     * @return priceSnapshot The decoded struct containing price and timestamps. Non-existent ID returns zero-initialized snapshots.
     */
    function fetch(
        bytes4 feedId
    ) external view returns (PriceSnapshot memory priceSnapshot);

    /**
     * @notice Returns decoded snapshots for multiple feeds.
     * @param feedIds Array of 4-byte identifiers.
     * @return priceSnapshots Array of decoded PriceSnapshot structs. For any feedIds that do not exist,
     * the corresponding positions in the array will contain zero-initialized snapshots.
     */
    function fetchBatch(
        bytes4[] calldata feedIds
    ) external view returns (PriceSnapshot[] memory priceSnapshots);

    // --- Compact Interface (Bare-Metal View) ---

    /**
     * @notice Returns the raw 256-bit packed word for a specific feed.
     * @dev Bypasses Solidity's default mapping access for O(1) gas efficiency.
     * @param feedId The 4-byte identifier.
     * @return packed Raw storage word: [Reserved(80b)][OnchainTs(48b)][AggTs(48b)][Price(80b)]. Non-existent ID returns bytes32(0).
     */
    function fetchCompact(bytes4 feedId) external view returns (bytes32 packed);

    /**
     * @notice Returns multiple raw packed words in a contiguous memory block.
     * @param feedIds Array of 4-byte identifiers.
     * @return packedList Array of raw 256-bit packed words. For any feedIds that do not exist, the corresponding positions in the array will contain bytes32(0)
     */
    function fetchCompactBatch(
        bytes4[] calldata feedIds
    ) external view returns (bytes32[] memory packedList);

    /**
     * @notice Returns the shared decimal precision for all feeds in this hub.
     * @return The constant value (typically 18).
     */
    function decimals() external view returns (uint8);

    /**
     * @notice Returns the human-readable description of this registry.
     * @return A string identifier.
     */
    function description() external view returns (string memory);

    /**
     * @notice Returns the version index of the current implementation.
     * @return Incremental version number for tracking upgrades.
     */
    function version() external view returns (uint256);

    /**
     * @notice Checks if an account is whitelisted as an authorized caller.
     * @param account The address to query.
     * @return True if the account is whitelisted.
     */
    function isAuthorizedCaller(address account) external view returns (bool);
}
