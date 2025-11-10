// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// 1. External Libraries
import { OwnableRoles } from "solady/auth/OwnableRoles.sol";
import { MerkleTreeLib } from "solady/utils/MerkleTreeLib.sol";

// 3. Local Interfaces
import { IModule } from "kam/interfaces/modules/IModule.sol";

// 4. Local Contracts (or base/lib contracts like ERC7540)
import { ERC7540, SafeTransferLib } from "../lib/ERC7540.sol";

/// @title VaultModule
/// @notice An abstract module for managing vault assets and settlement proposals.
/// All state is stored in a single, unique storage slot to prevent collisions.
abstract contract VaultModule is ERC7540, OwnableRoles, IModule {
    using SafeTransferLib for address;

    /* //////////////////////////////////////////////////////////////
                          ERRORS
    //////////////////////////////////////////////////////////////*/

    string constant NO_ACTIVE_PROPOSAL = "MW1";
    string constant COOLDOWN_NOT_ELAPSED = "MW2";
    string constant MISMATCHED_ARRAYS = "MW3";


    /* //////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event SettlementProposed(uint256 indexed newTotalAssets, bytes32 indexed newMerkleRoot, uint256 executeAfter);

    event ProposalCancelled(uint256 totalAssets, bytes32 merkleRoot);

    event SettlementExecuted(uint256 indexed totalAssets, bytes32 indexed merkleRoot);

    /* //////////////////////////////////////////////////////////////
                          STATE & ROLES
    //////////////////////////////////////////////////////////////*/

    uint256 public constant MANAGER_ROLE = _ROLE_4;
    uint256 public constant GUARDIAN_ROLE = _ROLE_5;

    // Struct that represents a proposed settlement
    struct SettlementProposal {
        uint256 totalExternalAssets;
        bytes32 merkleRoot;
        uint256 executeAfter;
    }

    // Struct that holds all state for this module, stored at a single unique slot
    struct VaultModuleStorage {
        uint256 totalExternalAssets;
        bytes32 merkleRoot;
        uint256 cooldownPeriod;
        SettlementProposal currentProposal;
    }

    // Unique storage slot calculated for collision prevention
    bytes32 private constant VAULT_MODULE_STORAGE_SLOT = keccak256("com.myvault.vaultmodule.storage");

    /// @notice Returns a pointer to the module's storage struct at its unique slot.
    function _getVaultModuleStorage() internal pure returns (VaultModuleStorage storage $) {
        bytes32 _slot = VAULT_MODULE_STORAGE_SLOT;
        // Use assembly to load the storage pointer from the fixed slot
        assembly {
            $.slot := _slot
        }
    }

    /* //////////////////////////////////////////////////////////////
                         PUBLIC GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the current total assets recorded for the vault.
    /// @return _assets The total assets, excluding pending deposit requests.
    function totalAssets() public view override returns (uint256 _assets) {
        return totalIdle() +  totalExternalAssets() - totalPendingDepositRequests();
    }

    /// @notice Returns the current total assets recorded for the vault.
    function totalIdle() public view returns(uint256){
        return asset().balanceOf(address(this));
    }

    function totalExternalAssets() public view returns(uint256) {
        VaultModuleStorage storage $ = _getVaultModuleStorage();
        return $.totalExternalAssets; 
    }

    /// @notice Returns the current Merkle Root of strategy assets.
    /// @return The Merkle root hash.
    function merkleRoot() public view returns (bytes32) {
        return _getVaultModuleStorage().merkleRoot;
    }

    /// @notice Returns the current active settlement proposal.
    /// @return The full settlement proposal struct, including total assets, Merkle root, and execution time.
    function currentProposal() public view returns (SettlementProposal memory) {
        return _getVaultModuleStorage().currentProposal;
    }

    /// @notice Returns the required cooldown period between proposal and execution.
    /// @return The cooldown period in seconds.
    function cooldownPeriod() public view returns (uint256) {
        return _getVaultModuleStorage().cooldownPeriod;
    }

    /* //////////////////////////////////////////////////////////////
                        CORE PROPOSAL LOGIC
    //////////////////////////////////////////////////////////////*/


    /// @notice Proposes a new settlement state (total assets and Merkle root).
    /// @param _totalExternalAssets The new external total asset amount to be set.
    /// @param _merkleRoot The Merkle root of the new strategy hol3dings.
    function proposeSettleTotalAssets(
        uint256 _totalExternalAssets,
        bytes32 _merkleRoot
    ) external onlyRoles(MANAGER_ROLE) {
        VaultModuleStorage storage $ = _getVaultModuleStorage();

        // Create the new proposal
        SettlementProposal memory _newProposal = SettlementProposal({
            totalExternalAssets: _totalExternalAssets,
            merkleRoot: _merkleRoot,
            executeAfter: block.timestamp + $.cooldownPeriod
        });

        $.currentProposal = _newProposal;

        // Emit event
        emit SettlementProposed(_newProposal.totalExternalAssets, _newProposal.merkleRoot, _newProposal.executeAfter);
    }

    /// @notice Allows a GUARDIAN to cancel the current settlement proposal.
    function cancelProposal() external onlyRoles(GUARDIAN_ROLE) {
        VaultModuleStorage storage $ = _getVaultModuleStorage();
        SettlementProposal memory _proposalToCancel = $.currentProposal;

        // Proposal must exist to be cancelled
        require(_proposalToCancel.executeAfter != 0, NO_ACTIVE_PROPOSAL);

        // Emit event before deleting the proposal data
        emit ProposalCancelled(_proposalToCancel.totalExternalAssets, _proposalToCancel.merkleRoot);

        // Clear the proposal
        delete $.currentProposal;
    }

    /// @notice Executes the current settlement proposal after the cooldown period.
    function executeProposal() external {
        VaultModuleStorage storage $ = _getVaultModuleStorage();
        SettlementProposal memory _proposal = $.currentProposal;

        // Check if a proposal exists
        require(_proposal.executeAfter != 0, NO_ACTIVE_PROPOSAL);

        // The time must be NOW or LATER than the executeAfter timestamp (cooldown elapsed)
        require(block.timestamp >= _proposal.executeAfter, COOLDOWN_NOT_ELAPSED);

        // Update the contract's state
        $.totalExternalAssets = _proposal.totalExternalAssets;
        $.merkleRoot = _proposal.merkleRoot;

        // Emit event
        emit SettlementExecuted($.totalExternalAssets, $.merkleRoot);

        // Clear the proposal
        delete $.currentProposal;
    }

    /* //////////////////////////////////////////////////////////////
                        UTILITY FUNCTIONS 
    //////////////////////////////////////////////////////////////*/

    /// @notice Validates a set of strategy holdings against a Merkle root.
    /// @param _strategies Array of strategy addresses.
    /// @param _values Array of strategy values (holdings).
    /// @param _merkleRoot The Merkle root to validate against.
    /// @return Whether the provided leaves correctly derive the given Merkle root.
    function validateTotalAssets(
        address[] calldata _strategies,
        uint256[] calldata _values,
        bytes32 _merkleRoot
    )
        external
        pure
        returns (bool)
    {
        uint256 _l = _strategies.length;
        require(_l == _values.length, MISMATCHED_ARRAYS);

        bytes32[] memory _leaves = new bytes32[](_l);
        for (uint256 _i; _i < _l; ++_i) {
            // Hash the strategy address and its value to form a leaf
            _leaves[_i] = keccak256(abi.encodePacked(_strategies[_i], _values[_i]));
        }

        bytes32 _root = MerkleTreeLib.root(_leaves);
        return _root == _merkleRoot;
    }

    /// @inheritdoc IModule      
    function selectors() external pure returns (bytes4[] memory _selectors) {
        _selectors = new bytes4[](35);
        _selectors[0] = this.DOMAIN_SEPARATOR.selector;
        _selectors[1] = this.allowance.selector;
        _selectors[2] = this.approve.selector;
        _selectors[3] = this.asset.selector;
        _selectors[4] = this.balanceOf.selector;
        _selectors[5] = this.convertToAssets.selector;
        _selectors[6] = this.convertToShares.selector;
        _selectors[7] = this.decimals.selector;
        // _selectors[8] = this.deposit.selector;
        _selectors[9] = this.maxDeposit.selector;
        _selectors[10] = this.maxMint.selector;
        _selectors[11] = this.maxRedeem.selector;
        _selectors[12] = this.maxWithdraw.selector;
        //  _selectors[13] = this.mint.selector;
        _selectors[14] = this.name.selector;
        _selectors[15] = this.nonces.selector;
        _selectors[16] = this.permit.selector;
        _selectors[17] = this.redeem.selector;
        _selectors[18] = this.symbol.selector;
        _selectors[19] = this.totalSupply.selector;
        _selectors[20] = this.totalAssets.selector;
        _selectors[21] = this.transfer.selector;
        _selectors[22] = this.transferFrom.selector;
        _selectors[23] = this.withdraw.selector;
        _selectors[24] = this.executeProposal.selector;
        _selectors[25] = this.validateTotalAssets.selector;
        _selectors[26] = this.cancelProposal.selector;
        _selectors[27] = this.merkleRoot.selector;
        _selectors[28] = this.proposeSettleTotalAssets.selector;
        _selectors[29] = this.cooldownPeriod.selector;
        _selectors[30] = this.currentProposal.selector;
        _selectors[31] = this.requestDeposit.selector;
        _selectors[32] = this.requestRedeem.selector;
        _selectors[33] = this.totalIdle.selector;
        _selectors[34] = this.totalExternalAssets.selector;
        return _selectors;
    }
}