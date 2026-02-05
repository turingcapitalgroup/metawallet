// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC7540Lib, ERC7540_FilledRequest, ERC7540_Request } from "./ERC7540Types.sol";

import { ERC4626 } from "solady/tokens/ERC4626.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/// @notice Simple ERC7540 async Tokenized Vault implementation
/// @author Solthodox (https://github.com/Solthodox)
abstract contract ERC7540 is ERC4626 {
    using SafeTransferLib for address;
    using ERC7540Lib for ERC7540_Request;
    using ERC7540Lib for ERC7540_FilledRequest;

    /* //////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a deposit request is submitted
    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address source, uint256 assets
    );

    /// @notice Emitted when a redeem request is submitted
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address source, uint256 shares
    );

    /// @notice Emitted when a deposit request is fulfilled
    event FulfillDepositRequest(address indexed controller, uint256 assets, uint256 shares);

    /// @notice Emitted when a redeem request is fulfilled
    event FulfillRedeemRequest(address indexed controller, uint256 shares, uint256 assets);

    /// @notice Emitted when an operator approval is set
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    /* //////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when an unauthorized address attempts to act as a controller
    error InvalidController();

    /// @notice Thrown when trying to deposit or interact with zero assets
    error InvalidZeroAssets();

    /// @notice Thrown when trying to redeem or interact with zero shares
    error InvalidZeroShares();

    /// @notice Thrown when trying to set an invalid operator, such as setting oneself as an operator
    error InvalidOperator();

    /* //////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:metawallet.storage.erc7540
    struct ERC7540Storage {
        /// @notice Pending deposit requests by controller
        mapping(address => ERC7540_Request) pendingDepositRequest;
        /// @notice Pending redeem requests by controller
        mapping(address => ERC7540_Request) pendingRedeemRequest;
        /// @notice Fulfilled deposit requests available to claim
        mapping(address => ERC7540_FilledRequest) claimableDepositRequest;
        /// @notice Fulfilled redeem requests available to claim
        mapping(address => ERC7540_FilledRequest) claimableRedeemRequest;
        /// @notice Operator approvals (controller => operator => approved)
        mapping(address controller => mapping(address operator => bool)) isOperator;
        /// @notice Sum of all pending deposit request assets
        uint256 totalPendingDepositRequests;
    }

    // keccak256(abi.encode(uint256(keccak256("metawallet.storage.erc7540")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC7540_STORAGE_LOCATION =
        0x1f258c11921df783aee40e51a8bea706dacc811ab5bbdb895d3bfcffe1a3ff00;

    /// @notice Returns a pointer to the ERC7540 storage struct at its unique slot
    function _getERC7540Storage() internal pure returns (ERC7540Storage storage $) {
        assembly {
            $.slot := ERC7540_STORAGE_LOCATION
        }
    }

    /// @notice Returns the total assets currently pending in deposit requests
    function totalPendingDepositRequests() public view returns (uint256) {
        ERC7540Storage storage $ = _getERC7540Storage();
        return $.totalPendingDepositRequests;
    }

    /// @inheritdoc ERC4626
    /// @dev Excludes pending deposit requests from the total
    function totalAssets() public view virtual override returns (uint256) {
        return super.totalAssets() - totalPendingDepositRequests();
    }

    /// @inheritdoc ERC4626
    /// @dev ERC-7540 async vaults do not support synchronous previews
    function previewDeposit(uint256) public pure override returns (uint256) {
        revert();
    }

    /// @inheritdoc ERC4626
    /// @dev ERC-7540 async vaults do not support synchronous previews
    function previewMint(uint256) public pure override returns (uint256) {
        revert();
    }

    /// @inheritdoc ERC4626
    /// @dev ERC-7540 async vaults do not support synchronous previews
    function previewWithdraw(uint256) public pure override returns (uint256) {
        revert();
    }

    /// @inheritdoc ERC4626
    /// @dev ERC-7540 async vaults do not support synchronous previews
    function previewRedeem(uint256) public pure override returns (uint256) {
        revert();
    }

    /// @inheritdoc ERC4626
    /// @dev Limited by the claimable deposit requests of the controller
    function maxDeposit(address to) public view virtual override returns (uint256 assets) {
        ERC7540Storage storage $ = _getERC7540Storage();
        return $.claimableDepositRequest[to].assets;
    }

    /// @inheritdoc ERC4626
    /// @dev Limited by the claimable deposit requests of the controller
    function maxMint(address to) public view virtual override returns (uint256 shares) {
        return convertToShares(maxDeposit(to));
    }

    /// @inheritdoc ERC4626
    /// @dev Limited by the claimable redeem requests of the controller
    function maxWithdraw(address owner) public view virtual override returns (uint256 assets) {
        return convertToAssets(maxRedeem(owner));
    }

    /// @inheritdoc ERC4626
    /// @dev Limited by the claimable redeem requests of the controller
    function maxRedeem(address owner) public view virtual override returns (uint256 shares) {
        ERC7540Storage storage $ = _getERC7540Storage();
        return $.claimableRedeemRequest[owner].shares;
    }

    /// @notice Submits an asynchronous deposit request
    /// @dev Transfers assets from owner into the vault and creates a pending request
    /// @param assets Amount of deposit assets to transfer from owner
    /// @param controller Controller of the request who can operate on it
    /// @param owner Source of the deposit assets
    /// @return requestId Identifier for the deposit request (always 0)
    function requestDeposit(
        uint256 assets,
        address controller,
        address owner
    )
        public
        virtual
        returns (uint256 requestId)
    {
        if (assets == 0) revert InvalidZeroAssets();
        requestId = _requestDeposit(assets, controller, owner, msg.sender);
    }

    /// @notice Submits an asynchronous redeem request
    /// @dev Takes control of shares from owner and creates a pending request.
    ///      If msg.sender is an operator of owner, bypasses the allowance check.
    /// @param shares Amount of shares to be redeemed
    /// @param controller Controller of the request who can operate on it
    /// @param owner Source of the shares to be redeemed
    /// @return requestId Identifier for the redeem request (always 0)
    function requestRedeem(
        uint256 shares,
        address controller,
        address owner
    )
        public
        virtual
        returns (uint256 requestId)
    {
        if (shares == 0) revert InvalidZeroShares();
        ERC7540Storage storage $ = _getERC7540Storage();
        address sender = $.isOperator[owner][msg.sender] ? owner : msg.sender;
        return _requestRedeem(shares, controller, sender, msg.sender);
    }

    /// @inheritdoc ERC4626
    /// @dev Delegates to `deposit(assets, receiver, msg.sender)`
    function deposit(uint256 assets, address receiver) public virtual override returns (uint256 shares) {
        return deposit(assets, receiver, msg.sender);
    }

    /// @notice Claims a processed deposit request by minting shares to receiver
    /// @param assets Amount of assets to claim
    /// @param receiver Address to receive the minted shares
    /// @param controller Controller of the deposit request
    /// @return shares Amount of shares minted
    function deposit(uint256 assets, address receiver, address controller) public virtual returns (uint256 shares) {
        _validateController(controller);
        ERC7540Storage storage $ = _getERC7540Storage();
        if (assets > maxDeposit(controller)) revert DepositMoreThanMax();
        ERC7540_FilledRequest memory claimable = $.claimableDepositRequest[controller];
        shares = claimable.convertToSharesUp(assets);
        (shares,) = _deposit(assets, shares, receiver, controller);
    }

    /// @inheritdoc ERC4626
    /// @dev Delegates to `mint(shares, receiver, msg.sender)`
    function mint(uint256 shares, address receiver) public virtual override returns (uint256 assets) {
        return mint(shares, receiver, msg.sender);
    }

    /// @notice Claims a processed deposit request by minting exact shares to receiver
    /// @param shares Exact amount of shares to mint
    /// @param receiver Address to receive the minted shares
    /// @param controller Controller of the deposit request
    /// @return assets Amount of assets consumed
    function mint(uint256 shares, address receiver, address controller) public virtual returns (uint256 assets) {
        _validateController(controller);
        if (shares > maxMint(controller)) revert MintMoreThanMax();
        ERC7540Storage storage $ = _getERC7540Storage();
        ERC7540_FilledRequest memory claimable = $.claimableDepositRequest[controller];
        assets = claimable.convertToAssetsUp(shares);
        (, assets) = _deposit(assets, shares, receiver, controller);
    }

    /// @inheritdoc ERC4626
    /// @dev Claims processed redemption request; only callable by controller or approved operator
    function redeem(uint256 shares, address to, address controller) public virtual override returns (uint256 assets) {
        if (shares > maxRedeem(controller)) revert RedeemMoreThanMax();
        _validateController(controller);
        ERC7540Storage storage $ = _getERC7540Storage();
        ERC7540_FilledRequest memory claimable = $.claimableRedeemRequest[controller];
        assets = claimable.convertToAssets(shares);
        (assets,) = _withdraw(assets, shares, to, controller);
    }

    /// @inheritdoc ERC4626
    /// @dev Claims processed redemption for exact assets; only callable by controller or approved operator
    function withdraw(uint256 assets, address to, address controller) public virtual override returns (uint256 shares) {
        if (assets > maxWithdraw(controller)) revert WithdrawMoreThanMax();
        _validateController(controller);
        ERC7540Storage storage $ = _getERC7540Storage();
        ERC7540_FilledRequest memory claimable = $.claimableRedeemRequest[controller];
        shares = claimable.convertToSharesUp(assets);
        (, shares) = _withdraw(assets, shares, to, controller);
    }

    /// @notice Returns the pending redemption request amount for a controller
    /// @param controller Address to check pending redemption for
    /// @return Amount of shares pending redemption
    function pendingRedeemRequest(address controller) public view virtual returns (uint256) {
        ERC7540Storage storage $ = _getERC7540Storage();
        return $.pendingRedeemRequest[controller].unwrap();
    }

    /// @notice Returns the pending deposit request amount for a controller
    /// @param controller Address to check pending deposit for
    /// @return Amount of assets pending deposit
    function pendingDepositRequest(address controller) public view virtual returns (uint256) {
        ERC7540Storage storage $ = _getERC7540Storage();
        return $.pendingDepositRequest[controller].unwrap();
    }

    /// @notice Returns the claimable deposit amount for a controller
    /// @param controller Address to check claimable deposit for
    /// @return Amount of assets available to claim
    function claimableDepositRequest(address controller) public view virtual returns (uint256) {
        return maxDeposit(controller);
    }

    /// @notice Returns the claimable redemption amount for a controller
    /// @param controller Address to check claimable redemption for
    /// @return Amount of shares available to claim
    function claimableRedeemRequest(address controller) public view virtual returns (uint256) {
        return maxRedeem(controller);
    }

    /// @dev Consumes a claimable deposit request, mints shares, and emits {Deposit}
    function _deposit(
        uint256 assets,
        uint256 shares,
        address receiver,
        address controller
    )
        internal
        virtual
        returns (uint256 sharesReturn, uint256 assetsReturn)
    {
        ERC7540Storage storage $ = _getERC7540Storage();
        unchecked {
            $.claimableDepositRequest[controller].assets -= assets;
            $.claimableDepositRequest[controller].shares -= shares;
        }
        $.totalPendingDepositRequests -= assets;
        _mint(receiver, shares);
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, assets)
            mstore(0x20, shares)
            let m := shr(96, not(0))
            log3(
                0x00,
                0x40,
                0xdcbc1c05240f31ff3ad067ef1ee35ce4997762752e3a095284754544f4c709d7,
                and(m, controller),
                and(m, receiver)
            )
        }
        return (shares, assets);
    }

    /// @dev Consumes a claimable redeem request, transfers assets, and emits {Withdraw}
    function _withdraw(
        uint256 assets,
        uint256 shares,
        address receiver,
        address controller
    )
        internal
        virtual
        returns (uint256 assetsReturn, uint256 sharesReturn)
    {
        ERC7540Storage storage $ = _getERC7540Storage();
        unchecked {
            $.claimableRedeemRequest[controller].assets -= assets;
            $.claimableRedeemRequest[controller].shares -= shares;
        }
        asset().safeTransfer(receiver, assets);
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, assets)
            mstore(0x20, shares)
            let m := shr(96, not(0))
            log4(
                0x00,
                0x40,
                0xfbde797d201c681b91056529119e0b02407c7bb96a4a2c75c01fc9667232c8db,
                and(m, controller),
                and(m, receiver),
                and(m, controller)
            )
        }
        return (assets, shares);
    }

    /// @dev Pulls assets from source and records a pending deposit request for the controller
    function _requestDeposit(
        uint256 assets,
        address controller,
        address owner,
        address source
    )
        internal
        virtual
        returns (uint256 requestId)
    {
        asset().safeTransferFrom(source, address(this), assets);
        ERC7540Storage storage $ = _getERC7540Storage();
        $.totalPendingDepositRequests += assets;
        $.pendingDepositRequest[controller] = $.pendingDepositRequest[controller].add(assets);
        emit DepositRequest(controller, owner, requestId, source, assets);
        return 0;
    }

    /// @dev Transfers shares from owner and records a pending redeem request for the controller
    function _requestRedeem(
        uint256 shares,
        address controller,
        address owner,
        address source
    )
        internal
        virtual
        returns (uint256 requestId)
    {
        _transfer(owner, address(this), shares);
        ERC7540Storage storage $ = _getERC7540Storage();
        $.pendingRedeemRequest[controller] = $.pendingRedeemRequest[controller].add(shares);
        emit RedeemRequest(controller, owner, requestId, source, shares);
        return 0;
    }

    /// @notice Sets or removes an operator for the caller
    /// @param operator Address of the operator
    /// @param approved Whether the operator is approved
    /// @return success Always true on success
    function setOperator(address operator, bool approved) public returns (bool success) {
        if (msg.sender == operator) revert InvalidOperator();
        ERC7540Storage storage $ = _getERC7540Storage();
        $.isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    /// @dev Reverts if msg.sender is neither the controller nor an approved operator
    function _validateController(address controller) internal view {
        if (msg.sender != controller && !_getERC7540Storage().isOperator[controller][msg.sender]) {
            revert InvalidController();
        }
    }

    /* //////////////////////////////////////////////////////////////
                          HOOKS TO OVERRIDE
    //////////////////////////////////////////////////////////////*/

    /// @dev Processes a pending deposit request, making it claimable by the controller
    function _fulfillDepositRequest(
        address controller,
        uint256 assetsFulfilled,
        uint256 sharesMinted
    )
        internal
        virtual
    {
        ERC7540Storage storage $ = _getERC7540Storage();
        $.pendingDepositRequest[controller] = $.pendingDepositRequest[controller].sub(assetsFulfilled);
        $.claimableDepositRequest[controller].assets += assetsFulfilled;
        $.claimableDepositRequest[controller].shares += sharesMinted;
        emit FulfillDepositRequest(controller, assetsFulfilled, sharesMinted);
    }

    /// @dev Processes a pending redeem request, making it claimable by the controller.
    ///      When `strict` is false, allows fulfilling more shares than pending (clamped to zero).
    function _fulfillRedeemRequest(
        uint256 sharesFulfilled,
        uint256 assetsWithdrawn,
        address controller,
        bool strict
    )
        internal
        virtual
    {
        ERC7540Storage storage $ = _getERC7540Storage();
        if (strict) {
            $.pendingRedeemRequest[controller] = $.pendingRedeemRequest[controller].sub(sharesFulfilled);
        } else {
            $.pendingRedeemRequest[controller] = $.pendingRedeemRequest[controller].sub0(sharesFulfilled);
        }
        $.claimableRedeemRequest[controller].assets += assetsWithdrawn;
        $.claimableRedeemRequest[controller].shares += sharesFulfilled;
        emit FulfillRedeemRequest(controller, sharesFulfilled, assetsWithdrawn);
    }
}
