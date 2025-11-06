// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC7540 } from "../lib/ERC7540.sol";
import { IModule } from "kam/interfaces/modules/IModule.sol";
import { OwnableRoles } from "solady/auth/OwnableRoles.sol";
import { MerkleTreeLib } from "solady/utils/MerkleTreeLib.sol";

/**
 * @title VaultModule
 * @notice An abstract module for managing vault assets and settlement proposals.
 * All state is stored in a single, unique storage slot to prevent collisions.
 */
abstract contract VaultModule is ERC7540, OwnableRoles {
    // --- Custom Errors ---

    /// @dev Thrown when an operation requires an active proposal, but none exists.
    error NoActiveProposal();

    /// @dev Thrown when attempting to execute a proposal before its cooldown period has finished.
    error CooldownNotElapsed();

    /// @dev Thrown when input arrays (strategies and values) do not have the same length.
    error MismatchedArrays();

    // --- State & Roles ---

    uint256 public constant MANAGER_ROLE = _ROLE_4;
    uint256 public constant GUARDIAN_ROLE = _ROLE_5;

    // Struct that represents a proposed settlement
    struct SettlementProposal {
        uint256 totalAssets;
        bytes32 merkleRoot;
        uint256 executeAfter;
    }

    // Struct that holds all state for this module, stored at a single unique slot
    struct VaultModuleStorage {
        uint256 totalAssets;
        bytes32 merkleRoot;
        uint256 cooldownPeriod;
        SettlementProposal currentProposal;
    }

    // Unique storage slot calculated for collision prevention
    bytes32 private constant VAULT_MODULE_STORAGE_SLOT = keccak256("com.myvault.vaultmodule.storage");

    /**
     * @notice Returns a pointer to the module's storage struct at its unique slot.
     */
    function _getVaultModuleStorage() internal pure returns (VaultModuleStorage storage s) {
        bytes32 slot = VAULT_MODULE_STORAGE_SLOT;
        // Use assembly to load the storage pointer from the fixed slot
        assembly {
            s.slot := slot
        }
    }

    // --- Events ---

    event SettlementProposed(uint256 indexed newTotalAssets, bytes32 indexed newMerkleRoot, uint256 executeAfter);

    event ProposalCancelled(uint256 totalAssets, bytes32 merkleRoot);

    event SettlementExecuted(uint256 indexed totalAssets, bytes32 indexed merkleRoot);

    // --- Public Getters (Implementing ERC7540) ---

    /**
     * @notice Returns the current total assets recorded for the vault.
     */
    function totalAssets() public view override returns (uint256 assets) {
        return _getVaultModuleStorage().totalAssets - totalPendingDepositRequests();
    }

    /**
     * @notice Returns the current Merkle Root of strategy assets.
     */
    function merkleRoot() public view returns (bytes32) {
        return _getVaultModuleStorage().merkleRoot;
    }

    /**
     * @notice Returns the current active settlement proposal.
     */
    function currentProposal() public view returns (SettlementProposal memory) {
        return _getVaultModuleStorage().currentProposal;
    }

    /**
     * @notice Returns the required cooldown period between proposal and execution.
     */
    function cooldownPeriod() public view returns (uint256) {
        return _getVaultModuleStorage().cooldownPeriod;
    }

    // --- Core Proposal Logic ---

    /**
     * @notice Proposes a new settlement state (total assets and Merkle root).
     * @param _totalAssets The new total asset amount to be set.
     * @param _merkleRoot The Merkle root of the new strategy holdings.
     */
    function proposeSettleTotalAssets(uint256 _totalAssets, bytes32 _merkleRoot) external onlyRoles(MANAGER_ROLE) {
        VaultModuleStorage storage s = _getVaultModuleStorage();

        // Create the new proposal
        SettlementProposal memory newProposal = SettlementProposal({
            totalAssets: _totalAssets, merkleRoot: _merkleRoot, executeAfter: block.timestamp + s.cooldownPeriod
        });

        s.currentProposal = newProposal;

        // Emit event
        emit SettlementProposed(newProposal.totalAssets, newProposal.merkleRoot, newProposal.executeAfter);
    }

    /**
     * @notice Allows a GUARDIAN to cancel the current settlement proposal.
     */
    function cancelProposal() external onlyRoles(GUARDIAN_ROLE) {
        VaultModuleStorage storage s = _getVaultModuleStorage();
        SettlementProposal memory proposalToCancel = s.currentProposal;

        // Proposal must exist to be cancelled
        if (proposalToCancel.executeAfter == 0) revert NoActiveProposal();

        // Emit event before deleting the proposal data
        emit ProposalCancelled(proposalToCancel.totalAssets, proposalToCancel.merkleRoot);

        // Clear the proposal
        delete s.currentProposal;
    }

    /**
     * @notice Executes the current settlement proposal after the cooldown period.
     */
    function executeProposal() external {
        VaultModuleStorage storage s = _getVaultModuleStorage();
        SettlementProposal memory proposal = s.currentProposal;

        // Check if a proposal exists
        if (proposal.executeAfter == 0) revert NoActiveProposal();

        // The time must be NOW or LATER than the executeAfter timestamp (cooldown elapsed)
        if (block.timestamp < proposal.executeAfter) revert CooldownNotElapsed();

        // Update the contract's state
        s.totalAssets = proposal.totalAssets;
        s.merkleRoot = proposal.merkleRoot;

        // Emit event
        emit SettlementExecuted(s.totalAssets, s.merkleRoot);

        // Clear the proposal
        delete s.currentProposal;
    }

    // --- Utility Functions ---

    /**
     * @notice Validates a set of strategy holdings against a Merkle root.
     */
    function validateTotalAssets(
        address[] calldata strategies,
        uint256[] calldata values,
        bytes32 merkleRoot
    )
        external
        pure
        returns (bool)
    {
        uint256 l = strategies.length;
        if (l != values.length) revert MismatchedArrays();

        bytes32[] memory leaves = new bytes32[](l);
        for (uint256 i; i < l; ++i) {
            // Hash the strategy address and its value to form a leaf
            leaves[i] = keccak256(abi.encodePacked(strategies[i], values[i]));
        }

        bytes32 root = MerkleTreeLib.root(leaves);
        return root == merkleRoot;
    }

    /**
     * @notice Returns the function selectors exposed by this module.
     */
    function selectors() external pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](33);
        selectors[0] = this.DOMAIN_SEPARATOR.selector;
        selectors[1] = this.allowance.selector;
        selectors[2] = this.approve.selector;
        selectors[3] = this.asset.selector;
        selectors[4] = this.balanceOf.selector;
        selectors[5] = this.convertToAssets.selector;
        selectors[6] = this.convertToShares.selector;
        selectors[7] = this.decimals.selector;
        // selectors[8] = this.deposit.selector;
        selectors[9] = this.maxDeposit.selector;
        selectors[10] = this.maxMint.selector;
        selectors[11] = this.maxRedeem.selector;
        selectors[12] = this.maxWithdraw.selector;
        //  selectors[13] = this.mint.selector;
        selectors[14] = this.name.selector;
        selectors[15] = this.nonces.selector;
        selectors[16] = this.permit.selector;
        selectors[17] = this.redeem.selector;
        selectors[18] = this.symbol.selector;
        selectors[19] = this.totalSupply.selector;
        selectors[20] = this.totalAssets.selector;
        selectors[21] = this.transfer.selector;
        selectors[22] = this.transferFrom.selector;
        selectors[23] = this.withdraw.selector;
        selectors[24] = this.executeProposal.selector;
        selectors[25] = this.validateTotalAssets.selector;
        selectors[26] = this.cancelProposal.selector;
        selectors[27] = this.merkleRoot.selector;
        selectors[28] = this.proposeSettleTotalAssets.selector;
        selectors[29] = this.cooldownPeriod.selector;
        selectors[30] = this.currentProposal.selector;
        selectors[31] = this.requestDeposit.selector;
        selectors[32] = this.requestRedeem.selector;
        return selectors;
    }
}
