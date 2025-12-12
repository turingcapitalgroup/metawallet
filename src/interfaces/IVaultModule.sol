// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVaultModule {
    /* //////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event SettlementExecuted(uint256 indexed totalAssets, bytes32 indexed merkleRoot);

    event Paused(address indexed account);

    event Unpaused(address indexed account);

    /// @notice Initializes the vault logic with asset and token metadata
    /// @param _asset The address of the underlying asset
    /// @param _name The name of the vault token
    /// @param _symbol The symbol of the vault token
    function initializeVault(address _asset, string memory _name, string memory _symbol) external;

    /// @notice Returns the estimate price of 1 vault share
    /// @return The price of one vault share in asset terms
    function sharePrice() external view returns (uint256);

    /// @notice Returns the current total idle assets (actual balance in vault)
    function totalIdle() external view returns (uint256);

    /// @notice Returns the current Merkle Root of strategy assets
    /// @return The Merkle root hash
    function merkleRoot() external view returns (bytes32);

    /// @notice Returns whether the vault is paused
    /// @return True if paused, false otherwise
    function paused() external view returns (bool);

    /// @notice Directly settles the total assets and merkle root
    /// @param _newTotalAssets The new total asset amount to be set
    /// @param _merkleRoot The Merkle root of the strategy holdings
    function settleTotalAssets(uint256 _newTotalAssets, bytes32 _merkleRoot) external;

    /// @notice Pauses the vault - only EMERGENCY_ADMIN can call
    function pause() external;

    /// @notice Unpauses the vault - only EMERGENCY_ADMIN can call
    function unpause() external;

    /// @notice Computes the Merkle root from strategy holdings
    /// @param _strategies Array of strategy addresses
    /// @param _values Array of strategy values (holdings)
    /// @return The computed Merkle root
    function computeMerkleRoot(
        address[] calldata _strategies,
        uint256[] calldata _values
    )
        external
        pure
        returns (bytes32);

    /// @notice Validates a set of strategy holdings against a Merkle root
    /// @param _strategies Array of strategy addresses
    /// @param _values Array of strategy values (holdings)
    /// @param _merkleRoot The Merkle root to validate against
    /// @return Whether the provided leaves correctly derive the given Merkle root
    function validateTotalAssets(
        address[] calldata _strategies,
        uint256[] calldata _values,
        bytes32 _merkleRoot
    )
        external
        pure
        returns (bool);
}
