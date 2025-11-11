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
/// @notice A module for managing vault assets and settlement proposals.
/// All state is stored in a single, unique storage slot to prevent collisions.
contract VaultModule is ERC7540, OwnableRoles, IModule {
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
        bool initialized;
        address asset;
        string name;
        string symbol;
        uint8 decimals;
    }

    // keccak256(abi.encode(uint256(keccak256("metawallet.storage.VaultModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VAULT_MODULE_STORAGE_LOCATION = 0x511216ea87b3ec844059069c7b970c812573d49674957e6b4ccb340e8aff7200;

    /// @notice Returns a pointer to the module's storage struct at its unique slot.
    function _getVaultModuleStorage() internal pure returns (VaultModuleStorage storage $) {
        bytes32 _slot = VAULT_MODULE_STORAGE_LOCATION;
        // Use assembly to load the storage pointer from the fixed slot
        assembly {
            $.slot := _slot
        }
    }

    /// @dev Initializes the vault logic
    function initializeVault(address _asset, string memory _name, string memory _symbol) external {
        VaultModuleStorage storage $ = _getVaultModuleStorage();
        if($.initialized) revert();
        $.asset = _asset;
        $.name = _name;
        $.symbol = _symbol;
        // Try to get asset decimals, revert if unsuccessful
        (bool success, uint8 result) = _tryGetAssetDecimals(_asset);
        if(!success) revert();
        $.decimals = result;
    }

    /* //////////////////////////////////////////////////////////////
                         ERC7540 Logic
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfers assets from sender into the Vault and submits a Request for asynchronous deposit.
    /// @param assets the amount of deposit assets to transfer from owner
    /// @param controller the controller of the request who will be able to operate the request
    /// @param owner the owner of the shares to be deposited
    /// @return requestId
    function requestDeposit(
        uint256 assets,
        address controller,
        address owner
    )
        public
        override
        returns (uint256 requestId)
    {
        if (owner != msg.sender) revert InvalidOperator();
        requestId = super.requestDeposit(assets, controller, owner);
        // fulfill the request directly
        _fulfillDepositRequest(controller, assets, convertToShares(assets));
    }

    /// @dev The redeem amount is limited by the claimable redeem requests of the user
    function maxRedeem(address owner) public view override returns (uint256 shares) {
        ERC7540Storage storage $ = _getERC7540Storage();
        uint256 _totalIdleShares = convertToShares(totalIdle());
        uint256 pendingShares = pendingRedeemRequest(owner);
        return _totalIdleShares > pendingShares ? pendingShares : pendingShares - _totalIdleShares;
    }

    /// @notice Claims processed redemption request
    /// @dev Can only be called by controller or approved operator
    /// @param shares Amount of shares to redeem
    /// @param to Address to receive the assets
    /// @param controller Controller of the redemption request
    /// @return assets Amount of assets returned
    function redeem(uint256 shares, address to, address controller) public virtual override returns (uint256 assets) {
        if (shares > maxRedeem(controller)) revert RedeemMoreThanMax();
        uint256 assets = convertToAssets(shares);
        _fulfillRedeemRequest(shares, assets, controller, true);
        _validateController(controller);
        ERC7540Storage storage $ = _getERC7540Storage();
        (assets,) = _withdraw(assets, shares, to, controller);
    }

    /// @notice Claims processed redemption request for exact assets
    /// @dev Can only be called by controller or approved operator
    /// @param assets Exact amount of assets to withdraw
    /// @param to Address to receive the assets
    /// @param controller Controller of the redemption request
    /// @return shares Amount of shares burned
    function withdraw(uint256 assets, address to, address controller) public virtual override returns (uint256 shares) {
        if (assets > maxWithdraw(controller)) revert WithdrawMoreThanMax();
        uint256 shares = convertToAssets(assets);
        _fulfillRedeemRequest(shares, assets, controller, true);
        _validateController(controller);
        ERC7540Storage storage $ = _getERC7540Storage();
        (, shares) = _withdraw(assets, shares, to, controller);
    }


    /* //////////////////////////////////////////////////////////////
                         PUBLIC GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the address of the underlying asset.
    function asset() public view override returns(address) {
        return _getVaultModuleStorage().asset;
    }

     /// @notice Returns the name of the token.
    function name() public view override returns(string memory) {
        return _getVaultModuleStorage().name;
    }

    /// @notice Returns the symbol of the token.
    function symbol() public view override returns(string memory) {
        return _getVaultModuleStorage().symbol;
    }
    
    /// @notice Returns the decimals of the token.
    function decimals() public view override returns(uint8) {
        return _getVaultModuleStorage().decimals;
    }

    /// @notice Returns the estimate price of 1 vault share
    function sharePrice() public view returns (uint256) {
        return convertToAssets(10 ** decimals());
    }

    /// @notice Returns the current total assets recorded for the vault.
    /// @return _assets The total assets, excluding pending deposit requests.
    function totalAssets() public view override returns (uint256 _assets) {
        return totalIdle() + totalExternalAssets();
    }

    /// @notice Returns the current total assets recorded for the vault.
    function totalIdle() public view returns (uint256) {
        return asset().balanceOf(address(this)) - totalPendingDepositRequests();
    }

    function totalExternalAssets() public view returns (uint256) {
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
    function proposeSettleTotalAssets(uint256 _totalExternalAssets, bytes32 _merkleRoot)
        external
        onlyRoles(MANAGER_ROLE)
    {
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
    function validateTotalAssets(address[] calldata _strategies, uint256[] calldata _values, bytes32 _merkleRoot)
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
