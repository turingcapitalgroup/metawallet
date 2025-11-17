// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVaultModule {
    /* //////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event SettlementProposed(uint256 indexed newTotalAssets, bytes32 indexed newMerkleRoot, uint256 executeAfter);

    event ProposalCancelled(uint256 totalAssets, bytes32 merkleRoot);

    event SettlementExecuted(uint256 indexed totalAssets, bytes32 indexed merkleRoot);

    struct SettlementProposal {
        uint256 totalExternalAssets;
        bytes32 merkleRoot;
        uint256 executeAfter;
    }

    /// @notice Initializes the vault logic with asset and token metadata
    /// @param _asset The address of the underlying asset
    /// @param _name The name of the vault token
    /// @param _symbol The symbol of the vault token
    function initializeVault(address _asset, string memory _name, string memory _symbol) external;

    /// @notice Returns the estimate price of 1 vault share
    /// @return The price of one vault share in asset terms
    function sharePrice() external view returns (uint256);

    /// @notice Returns the current total external assets recorded for the vault
    /// @return The total external assets
    function totalExternalAssets() external view returns (uint256);

    /// @notice Returns the current total idle assets recorded for the vault
    function totalIdle() external view returns (uint256);

    /// @notice Returns the current Merkle Root of strategy assets
    /// @return The Merkle root hash
    function merkleRoot() external view returns (bytes32);

    /// @notice Returns the current active settlement proposal
    /// @return The full settlement proposal struct, including total assets, Merkle root, and execution time
    function currentProposal() external view returns (SettlementProposal memory);

    /// @notice Returns the required cooldown period between proposal and execution
    /// @return The cooldown period in seconds
    function cooldownPeriod() external view returns (uint256);

    /// @notice Proposes a new settlement state (total assets and Merkle root)
    /// @param _totalExternalAssets The new external total asset amount to be set
    /// @param _merkleRoot The Merkle root of the new strategy holdings
    function proposeSettleTotalAssets(uint256 _totalExternalAssets, bytes32 _merkleRoot) external;

    /// @notice Allows a GUARDIAN to cancel the current settlement proposal
    function cancelProposal() external;

    /// @notice Executes the current settlement proposal after the cooldown period
    function executeProposal() external;

    /// @notice Validates a set of strategy holdings against a Merkle root
    /// @param _strategies Array of strategy addresses
    /// @param _values Array of strategy values (holdings)
    /// @param _merkleRoot The Merkle root to validate against
    /// @return Whether the provided leaves correctly derive the given Merkle root
    function validateTotalAssets(address[] calldata _strategies, uint256[] calldata _values, bytes32 _merkleRoot)
        external
        view
        returns (bool);
}
