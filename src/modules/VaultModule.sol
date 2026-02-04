// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { OwnableRoles } from "solady/auth/OwnableRoles.sol";
import { MerkleTreeLib } from "solady/utils/MerkleTreeLib.sol";

import { IModule } from "kam/interfaces/modules/IModule.sol";
import { IVaultModule } from "metawallet/src/interfaces/IVaultModule.sol";

import { ERC7540, SafeTransferLib } from "../lib/ERC7540.sol";

// Local Errors
import {
    VAULTMODULE_ALREADY_INITIALIZED,
    VAULTMODULE_DELTA_EXCEEDS_MAX,
    VAULTMODULE_INVALID_ASSET_DECIMALS,
    VAULTMODULE_INVALID_BPS,
    VAULTMODULE_MISMATCHED_ARRAYS,
    VAULTMODULE_PAUSED
} from "metawallet/src/errors/Errors.sol";

/// @title VaultModule
/// @notice A module for managing vault assets with virtual totalAssets tracking.
/// All state is stored in a single, unique storage slot to prevent collisions.
contract VaultModule is IVaultModule, ERC7540, OwnableRoles, IModule {
    using SafeTransferLib for address;

    /* //////////////////////////////////////////////////////////////
                          STATE & ROLES
    //////////////////////////////////////////////////////////////*/
    uint256 public constant ADMIN_ROLE = _ROLE_0;
    uint256 public constant WHITELISTED_ROLE = _ROLE_1;
    uint256 public constant MANAGER_ROLE = _ROLE_4;
    uint256 public constant EMERGENCY_ADMIN_ROLE = _ROLE_6;

    uint256 public constant BPS_DENOMINATOR = 10_000;

    // Struct that holds all state for this module, stored at a single unique slot
    struct VaultModuleStorage {
        uint256 virtualTotalAssets; // Virtual total assets, updated on deposit/redeem
        bytes32 merkleRoot;
        bool initialized;
        bool paused;
        address asset;
        string name;
        string symbol;
        uint8 decimals;
        uint256 maxAllowedDelta; // Max allowed delta in BPS (10000 = 100%)
    }

    // keccak256(abi.encode(uint256(keccak256("metawallet.storage.VaultModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VAULT_MODULE_STORAGE_LOCATION =
        0x511216ea87b3ec844059069c7b970c812573d49674957e6b4ccb340e8aff7200;

    /// @notice Returns a pointer to the module's storage struct at its unique slot.
    function _getVaultModuleStorage() internal pure returns (VaultModuleStorage storage $) {
        bytes32 _slot = VAULT_MODULE_STORAGE_LOCATION;
        assembly {
            $.slot := _slot
        }
    }

    /* //////////////////////////////////////////////////////////////
                          INTERNAL CHECKS
    //////////////////////////////////////////////////////////////*/

    function _checkNotPaused() internal view {
        require(!_getVaultModuleStorage().paused, VAULTMODULE_PAUSED);
    }

    function _checkAdminRole() internal view {
        _checkRoles(ADMIN_ROLE);
    }

    function _checkWhitelistedRole() internal view {
        _checkRoles(WHITELISTED_ROLE);
    }

    function _checkManagerRole() internal view {
        _checkRoles(MANAGER_ROLE);
    }

    function _checkEmergencyAdminRole() internal view {
        _checkRoles(EMERGENCY_ADMIN_ROLE);
    }

    /// @inheritdoc IVaultModule
    function initializeVault(address _asset, string memory _name, string memory _symbol) external {
        _checkAdminRole();
        VaultModuleStorage storage $ = _getVaultModuleStorage();
        require(!$.initialized, VAULTMODULE_ALREADY_INITIALIZED);
        $.asset = _asset;
        $.name = _name;
        $.symbol = _symbol;
        (bool success, uint8 result) = _tryGetAssetDecimals(_asset);
        require(success, VAULTMODULE_INVALID_ASSET_DECIMALS);
        $.decimals = result;
        $.initialized = true;
    }

    /* //////////////////////////////////////////////////////////////
                         ERC7540 Logic
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC7540
    /// @dev Immediately fulfills the deposit request after submission.
    function requestDeposit(
        uint256 assets,
        address controller,
        address owner
    )
        public
        override
        returns (uint256 requestId)
    {
        _checkWhitelistedRole();
        _checkNotPaused();
        if (owner != msg.sender) revert InvalidOperator();
        requestId = super.requestDeposit(assets, controller, owner);
        _fulfillDepositRequest(controller, assets, convertToShares(assets));
    }

    /// @inheritdoc ERC7540
    /// @dev Updates virtualTotalAssets to track deposited assets.
    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        _checkNotPaused();
        shares = super.deposit(assets, receiver, msg.sender);
        _getVaultModuleStorage().virtualTotalAssets += assets;
    }

    /// @inheritdoc ERC7540
    /// @dev Updates virtualTotalAssets to track deposited assets.
    function deposit(uint256 assets, address receiver, address controller) public override returns (uint256 shares) {
        _checkNotPaused();
        shares = super.deposit(assets, receiver, controller);
        _getVaultModuleStorage().virtualTotalAssets += assets;
    }

    /// @inheritdoc ERC7540
    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        _checkNotPaused();
        return mint(shares, receiver, msg.sender);
    }

    /// @inheritdoc ERC7540
    /// @dev Updates virtualTotalAssets to track minted assets.
    function mint(uint256 shares, address receiver, address controller) public override returns (uint256 assets) {
        _checkNotPaused();
        assets = super.mint(shares, receiver, controller);
        _getVaultModuleStorage().virtualTotalAssets += assets;
    }

    /// @inheritdoc ERC7540
    /// @dev Limited by both idle assets and pending redeem requests.
    function maxRedeem(address owner) public view override returns (uint256 shares) {
        uint256 _totalIdleShares = convertToShares(totalIdle());
        uint256 pendingShares = super.pendingRedeemRequest(owner);
        return _totalIdleShares >= pendingShares ? pendingShares : _totalIdleShares;
    }

    /// @inheritdoc ERC7540
    /// @dev Subtracts claimable shares from the total pending amount.
    function pendingRedeemRequest(address controller) public view override returns (uint256) {
        uint256 pending = super.pendingRedeemRequest(controller);
        return pending - maxRedeem(controller);
    }

    /// @inheritdoc ERC7540
    /// @dev Updates virtualTotalAssets to track withdrawn assets.
    function redeem(uint256 shares, address to, address controller) public virtual override returns (uint256 assets) {
        _checkNotPaused();
        _validateController(controller);
        if (shares > maxRedeem(controller)) revert RedeemMoreThanMax();
        assets = convertToAssets(shares);
        _fulfillRedeemRequest(shares, assets, controller, true);
        (assets,) = _withdraw(assets, shares, to, controller);
        _getVaultModuleStorage().virtualTotalAssets -= assets;
    }

    /// @inheritdoc ERC7540
    /// @dev Updates virtualTotalAssets to track withdrawn assets.
    function withdraw(uint256 assets, address to, address controller) public virtual override returns (uint256 shares) {
        _checkNotPaused();
        _validateController(controller);
        if (assets > maxWithdraw(controller)) revert WithdrawMoreThanMax();
        shares = convertToShares(assets);
        _fulfillRedeemRequest(shares, assets, controller, true);
        (, shares) = _withdraw(assets, shares, to, controller);
        _getVaultModuleStorage().virtualTotalAssets -= assets;
    }

    function _withdraw(
        uint256 assets,
        uint256 shares,
        address receiver,
        address controller
    )
        internal
        override
        returns (uint256 assetsReturn, uint256 sharesReturn)
    {
        _burn(address(this), shares);
        return super._withdraw(assets, shares, receiver, controller);
    }

    /* //////////////////////////////////////////////////////////////
                         PUBLIC GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the address of the underlying asset.
    function asset() public view override returns (address) {
        return _getVaultModuleStorage().asset;
    }

    /// @notice Returns the name of the token.
    function name() public view override returns (string memory) {
        return _getVaultModuleStorage().name;
    }

    /// @notice Returns the symbol of the token.
    function symbol() public view override returns (string memory) {
        return _getVaultModuleStorage().symbol;
    }

    /// @notice Returns the decimals of the token.
    function decimals() public view override returns (uint8) {
        return _getVaultModuleStorage().decimals;
    }

    /// @inheritdoc IVaultModule
    function sharePrice() public view returns (uint256) {
        return convertToAssets(10 ** decimals());
    }

    /// @inheritdoc ERC7540
    /// @dev Returns virtualTotalAssets rather than actual balance, updated on deposit/redeem/settlement.
    function totalAssets() public view override returns (uint256 _assets) {
        return _getVaultModuleStorage().virtualTotalAssets;
    }

    /// @inheritdoc IVaultModule
    function totalIdle() public view returns (uint256) {
        uint256 _balance = asset().balanceOf(address(this));
        uint256 _pending = totalPendingDepositRequests();
        if (_balance <= _pending) return 0;
        return _balance - _pending;
    }

    /// @inheritdoc IVaultModule
    function merkleRoot() public view returns (bytes32) {
        return _getVaultModuleStorage().merkleRoot;
    }

    /// @inheritdoc IVaultModule
    function paused() public view returns (bool) {
        return _getVaultModuleStorage().paused;
    }

    /// @inheritdoc IVaultModule
    function maxAllowedDelta() public view returns (uint256) {
        return _getVaultModuleStorage().maxAllowedDelta;
    }

    /// @inheritdoc IVaultModule
    function setMaxAllowedDelta(uint256 _maxAllowedDelta) external {
        _checkAdminRole();
        require(_maxAllowedDelta <= BPS_DENOMINATOR, VAULTMODULE_INVALID_BPS);
        _getVaultModuleStorage().maxAllowedDelta = _maxAllowedDelta;
        emit MaxAllowedDeltaUpdated(_maxAllowedDelta);
    }

    /* //////////////////////////////////////////////////////////////
                        SETTLEMENT LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVaultModule
    function settleTotalAssets(uint256 _newTotalAssets, bytes32 _merkleRoot) external {
        _checkManagerRole();
        VaultModuleStorage storage $ = _getVaultModuleStorage();

        uint256 _maxDelta = $.maxAllowedDelta;
        if (_maxDelta > 0) {
            uint256 _currentTotalAssets = $.virtualTotalAssets;
            if (_currentTotalAssets > 0) {
                uint256 _delta = _newTotalAssets > _currentTotalAssets
                    ? _newTotalAssets - _currentTotalAssets
                    : _currentTotalAssets - _newTotalAssets;
                uint256 _deltaBps = (_delta * BPS_DENOMINATOR) / _currentTotalAssets;
                require(_deltaBps <= _maxDelta, VAULTMODULE_DELTA_EXCEEDS_MAX);
            }
        }

        $.virtualTotalAssets = _newTotalAssets;
        $.merkleRoot = _merkleRoot;
        emit SettlementExecuted(_newTotalAssets, _merkleRoot);
    }

    /* //////////////////////////////////////////////////////////////
                        PAUSE LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVaultModule
    function pause() external {
        _checkEmergencyAdminRole();
        VaultModuleStorage storage $ = _getVaultModuleStorage();
        $.paused = true;
        emit Paused(msg.sender);
    }

    /// @inheritdoc IVaultModule
    function unpause() external {
        _checkEmergencyAdminRole();
        VaultModuleStorage storage $ = _getVaultModuleStorage();
        $.paused = false;
        emit Unpaused(msg.sender);
    }

    /* //////////////////////////////////////////////////////////////
                        UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVaultModule
    function computeMerkleRoot(
        address[] calldata _strategies,
        uint256[] calldata _values
    )
        public
        pure
        returns (bytes32)
    {
        uint256 _l = _strategies.length;
        require(_l == _values.length, VAULTMODULE_MISMATCHED_ARRAYS);

        bytes32[] memory _leaves = new bytes32[](_l);
        for (uint256 _i; _i < _l; ++_i) {
            _leaves[_i] = keccak256(abi.encodePacked(_strategies[_i], _values[_i]));
        }

        return MerkleTreeLib.root(_leaves);
    }

    /// @inheritdoc IVaultModule
    function validateTotalAssets(
        address[] calldata _strategies,
        uint256[] calldata _values,
        bytes32 _merkleRoot
    )
        external
        pure
        returns (bool)
    {
        return computeMerkleRoot(_strategies, _values) == _merkleRoot;
    }

    /// @inheritdoc IModule
    function selectors() external pure returns (bytes4[] memory _selectors) {
        _selectors = new bytes4[](44);
        _selectors[0] = this.DOMAIN_SEPARATOR.selector;
        _selectors[1] = this.allowance.selector;
        _selectors[2] = this.approve.selector;
        _selectors[3] = this.asset.selector;
        _selectors[4] = this.balanceOf.selector;
        _selectors[5] = this.convertToAssets.selector;
        _selectors[6] = this.convertToShares.selector;
        _selectors[7] = this.decimals.selector;
        _selectors[8] = bytes4(abi.encodeWithSignature("deposit(uint256,address)"));
        _selectors[9] = this.maxDeposit.selector;
        _selectors[10] = this.maxMint.selector;
        _selectors[11] = this.maxRedeem.selector;
        _selectors[12] = this.maxWithdraw.selector;
        _selectors[13] = bytes4(abi.encodeWithSignature("mint(uint256,address)"));
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
        _selectors[24] = this.validateTotalAssets.selector;
        _selectors[25] = this.merkleRoot.selector;
        _selectors[26] = this.settleTotalAssets.selector;
        _selectors[27] = this.requestDeposit.selector;
        _selectors[28] = this.requestRedeem.selector;
        _selectors[29] = this.totalIdle.selector;
        _selectors[30] = this.initializeVault.selector;
        _selectors[31] = this.claimableDepositRequest.selector;
        _selectors[32] = this.claimableRedeemRequest.selector;
        _selectors[33] = this.pendingDepositRequest.selector;
        _selectors[34] = this.pendingRedeemRequest.selector;
        _selectors[35] = this.sharePrice.selector;
        _selectors[36] = this.paused.selector;
        _selectors[37] = this.pause.selector;
        _selectors[38] = this.unpause.selector;
        _selectors[39] = bytes4(abi.encodeWithSignature("deposit(uint256,address,address)"));
        _selectors[40] = bytes4(abi.encodeWithSignature("mint(uint256,address,address)"));
        _selectors[41] = this.computeMerkleRoot.selector;
        _selectors[42] = this.maxAllowedDelta.selector;
        _selectors[43] = this.setMaxAllowedDelta.selector;
        return _selectors;
    }
}
