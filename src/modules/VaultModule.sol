// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { OwnableRoles } from "solady/auth/OwnableRoles.sol";
import { ERC4626 } from "solady/tokens/ERC4626.sol";
import { MerkleTreeLib } from "solady/utils/MerkleTreeLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { IModule } from "kam/interfaces/modules/IModule.sol";
import { IVaultModule } from "metawallet/src/interfaces/IVaultModule.sol";

import {
    VAULTMODULE_ALREADY_INITIALIZED,
    VAULTMODULE_DELTA_EXCEEDS_MAX,
    VAULTMODULE_INSUFFICIENT_IDLE,
    VAULTMODULE_INVALID_ASSET_DECIMALS,
    VAULTMODULE_INVALID_BPS,
    VAULTMODULE_MISMATCHED_ARRAYS,
    VAULTMODULE_PAUSED
} from "metawallet/src/errors/Errors.sol";

/// @title VaultModule
/// @notice A module for managing vault assets with virtual totalAssets tracking.
/// All state is stored in a single, unique storage slot to prevent collisions.
contract VaultModule is IVaultModule, ERC4626, OwnableRoles, IModule {
    using SafeTransferLib for address;

    /* //////////////////////////////////////////////////////////////
                          STATE & ROLES
    //////////////////////////////////////////////////////////////*/
    /// @notice Role for vault administration (initialization, configuration)
    uint256 public constant ADMIN_ROLE = _ROLE_0;
    /// @notice Role for whitelisted depositors
    uint256 public constant WHITELISTED_ROLE = _ROLE_2;
    /// @notice Role for settlement managers
    uint256 public constant MANAGER_ROLE = _ROLE_4;
    /// @notice Role for emergency pause/unpause operations
    uint256 public constant EMERGENCY_ADMIN_ROLE = _ROLE_6;

    /// @notice Basis points denominator (10000 = 100%)
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Default max allowed delta in BPS (10% = 1000 BPS)
    uint256 public constant DEFAULT_MAX_DELTA = 1000;

    struct VaultModuleStorage {
        uint256 virtualTotalAssets;
        bytes32 merkleRoot;
        bool initialized;
        bool paused;
        address asset;
        string name;
        string symbol;
        uint8 decimals;
        uint256 maxAllowedDelta;
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

    /// @dev Reverts if the vault is currently paused
    function _checkNotPaused() internal view {
        require(!_getVaultModuleStorage().paused, VAULTMODULE_PAUSED);
    }

    /// @dev Reverts if caller does not hold ADMIN_ROLE
    function _checkAdminRole() internal view {
        _checkRoles(ADMIN_ROLE);
    }

    /// @dev Reverts if caller does not hold WHITELISTED_ROLE
    function _checkWhitelistedRole() internal view {
        _checkRoles(WHITELISTED_ROLE);
    }

    /// @dev Reverts if caller does not hold MANAGER_ROLE
    function _checkManagerRole() internal view {
        _checkRoles(MANAGER_ROLE);
    }

    /// @dev Reverts if caller does not hold EMERGENCY_ADMIN_ROLE
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
        $.maxAllowedDelta = DEFAULT_MAX_DELTA;
        $.initialized = true;
    }

    /* //////////////////////////////////////////////////////////////
                         ERC4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC4626
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

    /// @inheritdoc ERC4626
    function decimals() public view override returns (uint8) {
        return _getVaultModuleStorage().decimals;
    }

    /// @inheritdoc ERC4626
    /// @dev Returns virtualTotalAssets rather than actual balance, updated on deposit/redeem/settlement.
    function totalAssets() public view override returns (uint256) {
        return _getVaultModuleStorage().virtualTotalAssets;
    }

    /// @inheritdoc ERC4626
    /// @dev Enforces WHITELISTED_ROLE and not paused. Updates virtualTotalAssets.
    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        _checkWhitelistedRole();
        _checkNotPaused();
        shares = super.deposit(assets, receiver);
        _getVaultModuleStorage().virtualTotalAssets += assets;
    }

    /// @inheritdoc ERC4626
    /// @dev Enforces WHITELISTED_ROLE and not paused. Updates virtualTotalAssets.
    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        _checkWhitelistedRole();
        _checkNotPaused();
        assets = super.mint(shares, receiver);
        _getVaultModuleStorage().virtualTotalAssets += assets;
    }

    /// @inheritdoc ERC4626
    /// @dev Enforces not paused. Updates virtualTotalAssets.
    function redeem(uint256 shares, address to, address owner) public override returns (uint256 assets) {
        _checkNotPaused();
        assets = convertToAssets(shares);
        require(assets <= totalIdle(), VAULTMODULE_INSUFFICIENT_IDLE);
        assets = super.redeem(shares, to, owner);
        _getVaultModuleStorage().virtualTotalAssets -= assets;
    }

    /// @inheritdoc ERC4626
    /// @dev Enforces not paused. Updates virtualTotalAssets.
    function withdraw(uint256 assets, address to, address owner) public override returns (uint256 shares) {
        _checkNotPaused();
        require(assets <= totalIdle(), VAULTMODULE_INSUFFICIENT_IDLE);
        shares = super.withdraw(assets, to, owner);
        _getVaultModuleStorage().virtualTotalAssets -= assets;
    }

    /// @inheritdoc ERC4626
    function maxDeposit(address) public view override returns (uint256) {
        return _getVaultModuleStorage().paused ? 0 : type(uint256).max;
    }

    /// @inheritdoc ERC4626
    function maxMint(address) public view override returns (uint256) {
        return _getVaultModuleStorage().paused ? 0 : type(uint256).max;
    }

    /// @inheritdoc ERC4626
    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 _ownerShares = balanceOf(owner);
        uint256 _idleShares = convertToShares(totalIdle());
        return _ownerShares < _idleShares ? _ownerShares : _idleShares;
    }

    /// @inheritdoc ERC4626
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 _ownerAssets = convertToAssets(balanceOf(owner));
        uint256 _idle = totalIdle();
        return _ownerAssets < _idle ? _ownerAssets : _idle;
    }

    /* //////////////////////////////////////////////////////////////
                         PUBLIC GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVaultModule
    function sharePrice() public view returns (uint256) {
        return convertToAssets(10 ** decimals());
    }

    /// @inheritdoc IVaultModule
    function totalIdle() public view returns (uint256) {
        return asset().balanceOf(address(this));
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

        return MerkleTreeLib.root(MerkleTreeLib.build(_leaves));
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
        _selectors = new bytes4[](40);
        _selectors[0] = this.DOMAIN_SEPARATOR.selector;
        _selectors[1] = this.allowance.selector;
        _selectors[2] = this.approve.selector;
        _selectors[3] = this.asset.selector;
        _selectors[4] = this.balanceOf.selector;
        _selectors[5] = this.convertToAssets.selector;
        _selectors[6] = this.convertToShares.selector;
        _selectors[7] = this.decimals.selector;
        _selectors[8] = this.deposit.selector;
        _selectors[9] = this.maxDeposit.selector;
        _selectors[10] = this.maxMint.selector;
        _selectors[11] = this.maxRedeem.selector;
        _selectors[12] = this.maxWithdraw.selector;
        _selectors[13] = this.mint.selector;
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
        _selectors[27] = this.totalIdle.selector;
        _selectors[28] = this.initializeVault.selector;
        _selectors[29] = this.sharePrice.selector;
        _selectors[30] = this.paused.selector;
        _selectors[31] = this.pause.selector;
        _selectors[32] = this.unpause.selector;
        _selectors[33] = this.computeMerkleRoot.selector;
        _selectors[34] = this.maxAllowedDelta.selector;
        _selectors[35] = this.setMaxAllowedDelta.selector;
        _selectors[36] = this.previewDeposit.selector;
        _selectors[37] = this.previewMint.selector;
        _selectors[38] = this.previewWithdraw.selector;
        _selectors[39] = this.previewRedeem.selector;
        return _selectors;
    }
}
