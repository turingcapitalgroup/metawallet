// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";

import { MetaWallet, MinimalSmartAccount } from "metawallet/src/MetaWallet.sol";
import { ERC4626ApproveAndDepositHook } from "metawallet/src/hooks/ERC4626ApproveAndDepositHook.sol";
import { MidnightHook } from "metawallet/src/hooks/MidnightHook.sol";
import { IHookExecution } from "metawallet/src/interfaces/IHookExecution.sol";
import { CollateralParams, IMidnight, Market, Offer } from "metawallet/src/interfaces/IMidnight.sol";
import { IMidnightModule } from "metawallet/src/interfaces/IMidnightModule.sol";
import { MidnightModule } from "metawallet/src/modules/MidnightModule.sol";
import { IRegistry } from "minimal-smart-account/interfaces/IRegistry.sol";
import { MinimalUUPSFactory } from "minimal-uups-factory/MinimalUUPSFactory.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";

import {
    HOOKMIDNIGHT_INACTIVE_CONTEXT,
    HOOKMIDNIGHT_INSUFFICIENT_OUTPUT,
    HOOKMIDNIGHT_INVALID_HOOK_DATA,
    MIDNIGHT_INSUFFICIENT_LIQUIDITY,
    MIDNIGHT_INVALID_BUYER,
    MIDNIGHT_INVALID_LIQUIDATION_STEP,
    MIDNIGHT_INVALID_MARKET,
    MIDNIGHT_INVALID_PLACEHOLDER_OFFSET,
    MIDNIGHT_INVALID_SELLER,
    MIDNIGHT_LIQUIDATION_CALL_FAILED,
    MIDNIGHT_ONLY_MIDNIGHT
} from "metawallet/src/errors/Errors.sol";

interface IMidnightProtocolDeployer {
    function deploy() external returns (address midnight, address setterRatifier);
}

interface ISetterRatifierRuntime {
    function setIsRootRatified(address maker, bytes32 root, bool newIsRootRatified) external;
}

interface IMidnightRuntime is IMidnight {
    function take(
        Offer memory offer,
        bytes memory ratifierData,
        uint256 units,
        address taker,
        address receiverIfTakerIsSeller,
        address takerCallback,
        bytes memory takerCallbackData
    )
        external
        returns (uint256 buyerAssets, uint256 sellerAssets);

    function repay(Market memory market, uint256 units, address onBehalf, address callback, bytes memory data) external;

    function supplyCollateral(Market memory market, uint256 collateralIndex, uint256 assets, address onBehalf) external;

    function creditOf(bytes32 id, address user) external view returns (uint128);

    function debtOf(bytes32 id, address user) external view returns (uint128);

    function consumed(address user, bytes32 group) external view returns (uint256);
}

contract MidnightTestToken is ERC20 {
    string private _name;
    string private _symbol;
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract StrictRegistry is IRegistry {
    mapping(address => mapping(bytes4 => bool)) public rejected;

    function setRejected(address target, bytes4 selector, bool value) external {
        rejected[target][selector] = value;
    }

    function authorizeCall(address target, bytes4 selector, bytes calldata) external view {
        require(!rejected[target][selector], "REGISTRY_REJECTED");
    }

    function isSelectorAllowed(address, address target, bytes4 selector) external view returns (bool) {
        return !rejected[target][selector];
    }
}

contract LiquidationAdapterHarness {
    MidnightTestToken public immutable token;
    uint256 public maxPerCall;

    constructor(MidnightTestToken token_) {
        token = token_;
    }

    function setMaxPerCall(uint256 maxPerCall_) external {
        maxPerCall = maxPerCall_;
    }

    function liquidate(uint256 assets, address receiver) external returns (uint256 assetsOut) {
        uint256 available = token.balanceOf(address(this));
        assetsOut = assets;
        if (maxPerCall != 0 && assetsOut > maxPerCall) assetsOut = maxPerCall;
        if (assetsOut > available) assetsOut = available;
        require(token.transfer(receiver, assetsOut), "TRANSFER_FAILED");
    }
}

contract RevertingLiquidationAdapter {
    function liquidate(uint256, address) external pure returns (uint256) {
        revert("ADAPTER_REVERT");
    }
}

contract QueueVaultHarness {
    MidnightTestToken public immutable token;

    constructor(MidnightTestToken token_) {
        token = token_;
    }

    function withdraw(uint256 assets, address receiver, address) external returns (uint256 shares) {
        require(token.transfer(receiver, assets), "TRANSFER_FAILED");
        return assets;
    }
}

contract BasicERC4626Vault is ERC20 {
    MidnightTestToken public immutable underlying;

    constructor(MidnightTestToken underlying_) {
        underlying = underlying_;
    }

    function name() public pure override returns (string memory) {
        return "Basic Vault";
    }

    function symbol() public pure override returns (string memory) {
        return "bVAULT";
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(underlying.transferFrom(msg.sender, address(this), assets), "TRANSFER_FROM_FAILED");
        _mint(receiver, assets);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        require(msg.sender == owner, "ONLY_OWNER");
        _burn(owner, assets);
        require(underlying.transfer(receiver, assets), "TRANSFER_FAILED");
        return assets;
    }

    function previewDeposit(uint256 assets) external pure returns (uint256) {
        return assets;
    }
}

contract OracleHarness {
    uint256 public price = 1e36;

    function setPrice(uint256 price_) external {
        price = price_;
    }
}

contract MidnightModuleTest is Test {
    uint256 internal constant ADMIN_ROLE = 1;
    uint256 internal constant EXECUTOR_ROLE = 2;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_TICK = 5820;
    uint256 internal constant INITIAL_BALANCE = 1_000_000 ether;

    bytes32 internal constant MIDNIGHT_HOOK_ID = keccak256("hook.midnight");
    bytes32 internal constant DEPOSIT_HOOK_ID = keccak256("hook.erc4626.deposit.midnight");

    bytes32 internal constant COLLATERAL_PARAMS_TYPEHASH =
        0xaf44a88eb50ebdbbebd980e5a23045c44f61ece5f80ab708a1bbe8718102e6af;
    bytes32 internal constant MARKET_TYPEHASH = 0x358117e98511cc3df97175dca58053b06675b43ad090b0553f8a1eff008b6e2e;
    bytes32 internal constant OFFER_TYPEHASH = 0x980a4cfc9766df84667f316d76e10cefc8caf04fb4cd4a9fca00a8e7b34f619c;

    StrictRegistry internal registry;
    MetaWallet internal proxy;
    MidnightModule internal midnightModule;
    MidnightHook internal midnightHook;
    address internal midnight;
    address internal ratifier;
    MidnightTestToken internal loanToken;
    MidnightTestToken internal collateralToken;
    OracleHarness internal oracle;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        registry = new StrictRegistry();
        MetaWallet implementation = new MetaWallet();
        MinimalUUPSFactory factory = new MinimalUUPSFactory();
        bytes memory initData = abi.encodeWithSelector(
            MinimalSmartAccount.initialize.selector, address(this), IRegistry(address(registry)), "midnight"
        );
        proxy = MetaWallet(
            payable(factory.deployDeterministicAndCall(address(implementation), keccak256("midnight"), initData))
        );

        proxy.grantRoles(address(this), ADMIN_ROLE | EXECUTOR_ROLE);
        midnightModule = new MidnightModule();
        proxy.addFunctions(midnightModule.selectors(), address(midnightModule), false);
        midnightHook = new MidnightHook(address(proxy));
        proxy.installHook(MIDNIGHT_HOOK_ID, address(midnightHook));

        loanToken = new MidnightTestToken("Loan", "LOAN", 18);
        collateralToken = new MidnightTestToken("Collateral", "COLL", 18);
        oracle = new OracleHarness();

        loanToken.mint(alice, INITIAL_BALANCE);
        loanToken.mint(bob, INITIAL_BALANCE);
        collateralToken.mint(alice, INITIAL_BALANCE);

        (midnight, ratifier) = _deployMidnightProtocol();
        IMidnightModule(address(proxy)).setMidnightConfig(midnight);
        IMidnightModule(address(proxy)).setIdleLiquidityCap(address(loanToken), type(uint256).max);
        _executeSetAuthorization(ratifier, true);

        vm.startPrank(alice);
        loanToken.approve(midnight, type(uint256).max);
        collateralToken.approve(midnight, type(uint256).max);
        IMidnight(midnight).setIsAuthorized(ratifier, true, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        loanToken.approve(midnight, type(uint256).max);
        IMidnight(midnight).setIsAuthorized(ratifier, true, bob);
        vm.stopPrank();
    }

    function _deployMidnightProtocol() internal returns (address deployedMidnight, address setterRatifier) {
        bytes memory bytecode = vm.getCode("MidnightProtocolDeployer.t.sol:MidnightProtocolDeployer");
        address deployer;
        assembly ("memory-safe") {
            deployer := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployer != address(0), "DEPLOYER_DEPLOY_FAILED");
        return IMidnightProtocolDeployer(deployer).deploy();
    }

    function _executeMidnightHook(
        MidnightHook.Action _action,
        bytes memory _actionData,
        uint256 _minAmountOut
    )
        internal
        returns (bytes[] memory _results)
    {
        return _executeMidnightHookWithNonce(_action, _actionData, _minAmountOut, proxy.nonce());
    }

    function _executeMidnightHookWithNonce(
        MidnightHook.Action _action,
        bytes memory _actionData,
        uint256 _minAmountOut,
        uint256 _expectedNonce
    )
        internal
        returns (bytes[] memory _results)
    {
        IHookExecution.HookExecution[] memory hooks = new IHookExecution.HookExecution[](1);
        hooks[0] = IHookExecution.HookExecution({
            hookId: MIDNIGHT_HOOK_ID,
            data: abi.encode(
                MidnightHook.HookData({ action: _action, actionData: _actionData, minAmountOut: _minAmountOut })
            )
        });
        return proxy.executeWithHookExecution(_expectedNonce, block.timestamp + 1, hooks);
    }

    function _executeSetAuthorization(address _authorized, bool _enabled) internal {
        _executeMidnightHook(
            MidnightHook.Action.SetAuthorization,
            abi.encode(
                MidnightHook.SetAuthorizationData({ midnight: midnight, authorized: _authorized, enabled: _enabled })
            ),
            0
        );
    }

    function _executeRatifyOfferRoot(bytes32 _root, bool _enabled) internal {
        _executeMidnightHook(
            MidnightHook.Action.RatifyOfferTree,
            abi.encode(MidnightHook.RatifyOfferTreeData({ setterRatifier: ratifier, root: _root, enabled: _enabled })),
            0
        );
    }

    function _executeCancelOfferGroup(bytes32 _group, uint256 _amount) internal {
        _executeMidnightHook(
            MidnightHook.Action.CancelOfferGroup,
            abi.encode(MidnightHook.CancelOfferGroupData({ midnight: midnight, group: _group, amount: _amount })),
            0
        );
    }

    function _executeWithdrawCredits(Market memory _withdrawMarket, uint256 _units, address _receiver) internal {
        _executeMidnightHook(
            MidnightHook.Action.WithdrawCredits,
            abi.encode(
                MidnightHook.WithdrawCreditsData({
                    midnight: midnight, market: _withdrawMarket, units: _units, receiver: _receiver
                })
            ),
            0
        );
    }

    function _executeTakeOffer(
        Offer memory _offer,
        bytes memory _ratifierData,
        uint256 _units,
        address _receiverIfTakerIsSeller,
        address _takerCallback,
        bytes memory _takerCallbackData
    )
        internal
        returns (uint256 _buyerAssets, uint256 _sellerAssets)
    {
        return _executeTakeOfferWithNonce(
            _offer, _ratifierData, _units, _receiverIfTakerIsSeller, _takerCallback, _takerCallbackData, proxy.nonce()
        );
    }

    function _executeTakeOfferWithNonce(
        Offer memory _offer,
        bytes memory _ratifierData,
        uint256 _units,
        address _receiverIfTakerIsSeller,
        address _takerCallback,
        bytes memory _takerCallbackData,
        uint256 _expectedNonce
    )
        internal
        returns (uint256 _buyerAssets, uint256 _sellerAssets)
    {
        bytes[] memory _results = _executeMidnightHookWithNonce(
            MidnightHook.Action.TakeOffer,
            abi.encode(
                MidnightHook.TakeOfferData({
                    midnight: midnight,
                    offer: _offer,
                    ratifierData: _ratifierData,
                    units: _units,
                    receiverIfTakerIsSeller: _receiverIfTakerIsSeller,
                    takerCallback: _takerCallback,
                    takerCallbackData: _takerCallbackData
                })
            ),
            0,
            _expectedNonce
        );
        if (_results.length <= 1) return (0, 0);
        return abi.decode(_results[1], (uint256, uint256));
    }

    function testOnBuyUsesIdleBalanceWhenCapCoversAssets() public {
        loanToken.mint(address(proxy), 100 ether);
        IMidnightModule(address(proxy)).setIdleLiquidityCap(address(loanToken), 100 ether);

        Market memory market = _market();
        (Offer memory offer, bytes memory ratifierData) = _ratifiedSellOfferFromAlice(market);
        IMidnightModule.BuyCallbackData memory data = IMidnightModule.BuyCallbackData({
            expectedMarketId: IMidnight(midnight).toId(market),
            withdrawalQueueId: bytes32(0),
            minFinalLoanTokenBalance: 0
        });

        _executeTakeOffer(offer, ratifierData, 40 ether, address(0), address(proxy), abi.encode(data));

        assertEq(loanToken.balanceOf(address(proxy)), 60 ether);
        assertEq(loanToken.balanceOf(alice), INITIAL_BALANCE + 40 ether);
        assertEq(IMidnightRuntime(midnight).creditOf(IMidnight(midnight).toId(market), address(proxy)), 40 ether);
        assertEq(IMidnightRuntime(midnight).debtOf(IMidnight(midnight).toId(market), alice), 40 ether);
    }

    function testOnBuyPreservesProtectedIdleWithQueueFunding() public {
        loanToken.mint(address(proxy), 100 ether);
        IMidnightModule(address(proxy)).setIdleLiquidityCap(address(loanToken), 60 ether);
        LiquidationAdapterHarness adapter = new LiquidationAdapterHarness(loanToken);
        loanToken.mint(address(adapter), 20 ether);
        _setAdapterQueue(adapter, 0, 0);

        Market memory market = _market();
        (Offer memory offer, bytes memory ratifierData) = _ratifiedSellOfferFromAlice(market);
        _executeTakeOffer(offer, ratifierData, 70 ether, address(0), address(proxy), abi.encode(_buyData(market, 0)));

        assertEq(loanToken.balanceOf(address(proxy)), 40 ether);
        assertEq(loanToken.balanceOf(alice), INITIAL_BALANCE + 70 ether);
    }

    function testOnBuyFundsFromERC4626WithdrawQueue() public {
        QueueVaultHarness vault = new QueueVaultHarness(loanToken);
        loanToken.mint(address(vault), 50 ether);
        _setVaultQueue(vault, 0);

        Market memory market = _market();
        (Offer memory offer, bytes memory ratifierData) = _ratifiedSellOfferFromAlice(market);
        _executeTakeOffer(offer, ratifierData, 50 ether, address(0), address(proxy), abi.encode(_buyData(market, 0)));

        assertEq(loanToken.balanceOf(address(proxy)), 0);
        assertEq(loanToken.balanceOf(alice), INITIAL_BALANCE + 50 ether);
    }

    function testOnBuyFundsFromAdapterQueue() public {
        LiquidationAdapterHarness adapter = new LiquidationAdapterHarness(loanToken);
        loanToken.mint(address(adapter), 30 ether);
        _setAdapterQueue(adapter, 0, 0);

        Market memory market = _market();
        (Offer memory offer, bytes memory ratifierData) = _ratifiedSellOfferFromAlice(market);
        _executeTakeOffer(offer, ratifierData, 30 ether, address(0), address(proxy), abi.encode(_buyData(market, 0)));

        assertEq(loanToken.balanceOf(alice), INITIAL_BALANCE + 30 ether);
    }

    function testOnBuyFundsFromMultipleQueueSteps() public {
        LiquidationAdapterHarness first = new LiquidationAdapterHarness(loanToken);
        LiquidationAdapterHarness second = new LiquidationAdapterHarness(loanToken);
        first.setMaxPerCall(20 ether);
        loanToken.mint(address(first), 20 ether);
        loanToken.mint(address(second), 40 ether);
        _setTwoAdapterQueue(first, second);

        Market memory market = _market();
        (Offer memory offer, bytes memory ratifierData) = _ratifiedSellOfferFromAlice(market);
        _executeTakeOffer(offer, ratifierData, 55 ether, address(0), address(proxy), abi.encode(_buyData(market, 0)));

        assertEq(loanToken.balanceOf(alice), INITIAL_BALANCE + 55 ether);
    }

    function testWithdrawCreditsAfterRepayment() public {
        Market memory market = _market();
        _createRepaidWalletCredit(market, 75 ether);

        _executeWithdrawCredits(market, 75 ether, bob);

        assertEq(loanToken.balanceOf(bob), INITIAL_BALANCE + 75 ether);
        assertEq(IMidnightRuntime(midnight).creditOf(IMidnight(midnight).toId(market), address(proxy)), 0);
    }

    function testPostedBuyOfferLiquidatesVaultThenWithdrawsAtMaturity() public {
        Market memory market = _market();
        BasicERC4626Vault vault = new BasicERC4626Vault(loanToken);
        uint256 investedAssets = 120 ether;
        uint256 units = 80 ether;

        loanToken.mint(address(proxy), investedAssets);
        _depositWalletAssetsIntoVault(vault, investedAssets);
        _setBasicVaultQueue(vault, 0);
        IMidnightModule(address(proxy)).setIdleLiquidityCap(address(loanToken), 0);

        Offer memory offer = _buyOfferFromWallet(market, 0);
        bytes memory ratifierData = _ratifyWalletOffer(offer);

        _collateralizeAlice(market, 1_000_000 ether);
        vm.prank(alice);
        (uint256 buyerAssets, uint256 sellerAssets) =
            IMidnightRuntime(midnight).take(offer, ratifierData, units, alice, alice, address(0), "");

        assertEq(buyerAssets, sellerAssets);
        assertLt(buyerAssets, units);
        assertEq(loanToken.balanceOf(address(proxy)), 0);
        assertEq(vault.balanceOf(address(proxy)), investedAssets - buyerAssets);
        assertEq(IMidnightRuntime(midnight).creditOf(IMidnight(midnight).toId(market), address(proxy)), units);

        vm.warp(market.maturity + 1);
        uint256 bobBefore = loanToken.balanceOf(bob);
        vm.prank(alice);
        IMidnightRuntime(midnight).repay(market, units, alice, address(0), "");

        _executeWithdrawCredits(market, units, bob);

        assertEq(loanToken.balanceOf(bob) - bobBefore, units);
        assertGt(units, buyerAssets);
        assertEq(IMidnightRuntime(midnight).creditOf(IMidnight(midnight).toId(market), address(proxy)), 0);
    }

    function testPostedBuyOfferLiquidatesVaultThenSellsCreditAtDiscount() public {
        Market memory market = _market();
        BasicERC4626Vault vault = new BasicERC4626Vault(loanToken);
        uint256 investedAssets = 120 ether;
        uint256 units = 80 ether;

        loanToken.mint(address(proxy), investedAssets);
        _depositWalletAssetsIntoVault(vault, investedAssets);
        _setBasicVaultQueue(vault, 0);
        IMidnightModule(address(proxy)).setIdleLiquidityCap(address(loanToken), 0);

        Offer memory walletOffer = _buyOfferFromWallet(market, 0);
        bytes memory walletRatifierData = _ratifyWalletOffer(walletOffer);

        _collateralizeAlice(market, 1_000_000 ether);
        vm.prank(alice);
        IMidnightRuntime(midnight).take(walletOffer, walletRatifierData, units, alice, alice, address(0), "");

        Offer memory bobBuyOffer = _buyOfferFromBob(market, 0);
        bytes memory bobRatifierData = _ratifyBobOffer(bobBuyOffer);

        (uint256 buyerAssets, uint256 sellerAssets) =
            _executeTakeOffer(bobBuyOffer, bobRatifierData, units, address(proxy), address(0), "");

        assertEq(buyerAssets, sellerAssets);
        assertLt(sellerAssets, units);
        assertEq(loanToken.balanceOf(address(proxy)), sellerAssets);
        assertEq(IMidnightRuntime(midnight).creditOf(IMidnight(midnight).toId(market), address(proxy)), 0);
    }

    function testDirectTakeOfferEarlyCreditSale() public {
        Market memory market = _market();
        _createWalletCredit(market, 80 ether);
        (Offer memory offer, bytes memory ratifierData) = _ratifiedBuyOfferFromAlice(market);

        (uint256 buyerAssets, uint256 sellerAssets) =
            _executeTakeOffer(offer, ratifierData, 80 ether, address(proxy), address(0), "");

        assertEq(buyerAssets, 80 ether);
        assertEq(sellerAssets, 80 ether);
        assertEq(loanToken.balanceOf(address(proxy)), 80 ether);
        assertEq(IMidnightRuntime(midnight).creditOf(IMidnight(midnight).toId(market), address(proxy)), 0);
    }

    function testMakerSideReduceOnlySellOfferCallbackUsesMerkleRatifier() public {
        Market memory market = _market();
        _createWalletCredit(market, 25 ether);
        (Offer memory offer, bytes memory ratifierData) = _ratifiedSellOfferFromWallet(market, address(proxy));

        vm.prank(alice);
        IMidnightRuntime(midnight).take(offer, ratifierData, 25 ether, alice, address(0), address(0), "");

        assertEq(loanToken.balanceOf(address(proxy)), 25 ether);
        assertEq(IMidnightRuntime(midnight).creditOf(IMidnight(midnight).toId(market), address(proxy)), 0);
    }

    function testWithdrawCreditsHookOutputsAndChainsIntoDepositHook() public {
        Market memory market = _market();
        _createRepaidWalletCredit(market, 33 ether);
        ERC4626ApproveAndDepositHook depositHook = new ERC4626ApproveAndDepositHook(address(proxy));
        BasicERC4626Vault vault = new BasicERC4626Vault(loanToken);
        vm.prank(address(proxy));
        depositHook.setVaultAllowed(address(vault), true);
        proxy.installHook(DEPOSIT_HOOK_ID, address(depositHook));

        IHookExecution.HookExecution[] memory hooks = new IHookExecution.HookExecution[](2);
        hooks[0] = IHookExecution.HookExecution({
            hookId: MIDNIGHT_HOOK_ID,
            data: abi.encode(
                MidnightHook.HookData({
                    action: MidnightHook.Action.WithdrawCredits,
                    actionData: abi.encode(
                        MidnightHook.WithdrawCreditsData({
                            midnight: midnight, market: market, units: 33 ether, receiver: address(depositHook)
                        })
                    ),
                    minAmountOut: 33 ether
                })
            )
        });
        hooks[1] = IHookExecution.HookExecution({
            hookId: DEPOSIT_HOOK_ID,
            data: abi.encode(
                ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                    vault: address(vault), assets: type(uint256).max, receiver: bob, minShares: 33 ether
                })
            )
        });

        proxy.executeWithHookExecution(proxy.nonce(), block.timestamp + 1, hooks);

        assertEq(vault.balanceOf(bob), 33 ether);
    }

    function testTakeOfferHookOutputsAndRejectsInvalidData() public {
        Market memory market = _market();
        _createWalletCredit(market, 44 ether);
        (Offer memory offer, bytes memory ratifierData) = _ratifiedBuyOfferFromAlice(market);

        IHookExecution.HookExecution[] memory hooks = new IHookExecution.HookExecution[](1);
        hooks[0] = IHookExecution.HookExecution({
            hookId: MIDNIGHT_HOOK_ID,
            data: abi.encode(
                MidnightHook.HookData({
                    action: MidnightHook.Action.TakeOffer,
                    actionData: abi.encode(
                        MidnightHook.TakeOfferData({
                            midnight: midnight,
                            offer: offer,
                            ratifierData: ratifierData,
                            units: 44 ether,
                            receiverIfTakerIsSeller: address(proxy),
                            takerCallback: address(0),
                            takerCallbackData: ""
                        })
                    ),
                    minAmountOut: 44 ether
                })
            )
        });
        proxy.executeWithHookExecution(proxy.nonce(), block.timestamp + 1, hooks);
        assertEq(loanToken.balanceOf(address(proxy)), 44 ether);

        bytes memory invalidData = abi.encode(
            MidnightHook.HookData({
                action: MidnightHook.Action.TakeOffer,
                actionData: abi.encode(
                    MidnightHook.TakeOfferData({
                        midnight: address(0),
                        offer: offer,
                        ratifierData: ratifierData,
                        units: 1,
                        receiverIfTakerIsSeller: address(proxy),
                        takerCallback: address(0),
                        takerCallbackData: ""
                    })
                ),
                minAmountOut: 0
            })
        );
        vm.expectRevert(bytes(HOOKMIDNIGHT_INVALID_HOOK_DATA));
        midnightHook.buildExecutions(address(0), invalidData);
    }

    function testMidnightHookCancelsOfferGroup() public {
        bytes32 group = keccak256("wallet-offer-group");

        _executeCancelOfferGroup(group, 12 ether);

        assertEq(IMidnightRuntime(midnight).consumed(address(proxy), group), 12 ether);
    }

    function testCallbackValidationReverts() public {
        Market memory market = _market();
        bytes32 id = IMidnight(midnight).toId(market);

        vm.expectRevert(bytes(MIDNIGHT_ONLY_MIDNIGHT));
        IMidnightModule(address(proxy)).onBuy(id, market, 1, 1, 0, address(proxy), "");

        vm.prank(midnight);
        vm.expectRevert(bytes(MIDNIGHT_INVALID_BUYER));
        IMidnightModule(address(proxy)).onBuy(id, market, 1, 1, 0, alice, "");

        vm.prank(midnight);
        vm.expectRevert(bytes(MIDNIGHT_INVALID_SELLER));
        IMidnightModule(address(proxy)).onSell(id, market, 1, 1, 0, alice, bob, "");

        (Offer memory offer, bytes memory ratifierData) = _ratifiedSellOfferFromAlice(market);
        uint256 invalidMarketNonce = proxy.nonce();
        vm.expectRevert(bytes(MIDNIGHT_INVALID_MARKET));
        _executeTakeOfferWithNonce(
            offer,
            ratifierData,
            1 ether,
            address(0),
            address(proxy),
            abi.encode(_buyDataWithId(bytes32(uint256(1)), 0)),
            invalidMarketNonce
        );
    }

    function testQueueAndFundingValidationReverts() public {
        Market memory market = _market();
        (Offer memory sellOffer, bytes memory ratifierData) = _ratifiedSellOfferFromAlice(market);
        bytes memory buyData = abi.encode(_buyData(market, 0));

        uint256 noLiquidityNonce = proxy.nonce();
        vm.expectRevert(bytes(MIDNIGHT_INSUFFICIENT_LIQUIDITY));
        _executeTakeOfferWithNonce(
            sellOffer, ratifierData, 10 ether, address(0), address(proxy), buyData, noLiquidityNonce
        );

        loanToken.mint(address(proxy), 100 ether);
        IMidnightModule(address(proxy)).setIdleLiquidityCap(address(loanToken), 0);
        uint256 protectedIdleNonce = proxy.nonce();
        vm.expectRevert(bytes(MIDNIGHT_INSUFFICIENT_LIQUIDITY));
        _executeTakeOfferWithNonce(
            sellOffer, ratifierData, 1 ether, address(0), address(proxy), buyData, protectedIdleNonce
        );

        LiquidationAdapterHarness adapter = new LiquidationAdapterHarness(loanToken);
        bytes32 queueId = IMidnightModule(address(proxy)).loanTokenQueueId(address(loanToken));
        IMidnightModule.WithdrawalStep[] memory steps = new IMidnightModule.WithdrawalStep[](1);
        steps[0] = _rawCallStep(
            address(adapter),
            abi.encodeWithSelector(LiquidationAdapterHarness.liquidate.selector, uint256(0), address(proxy)),
            0,
            0
        );
        vm.expectRevert(bytes(MIDNIGHT_INVALID_PLACEHOLDER_OFFSET));
        IMidnightModule(address(proxy)).setWithdrawalQueue(queueId, address(loanToken), steps);

        steps[0] = _adapterStep(adapter, 0, 0);
        steps[0].amountPlaceholderOffset = 4;
        vm.expectRevert(bytes(MIDNIGHT_INVALID_LIQUIDATION_STEP));
        IMidnightModule(address(proxy)).setWithdrawalQueue(queueId, address(loanToken), steps);

        steps[0] = _adapterStep(adapter, 0, 0);
        steps[0].expectedOutputToken = address(0xBAD);
        vm.expectRevert(bytes(MIDNIGHT_INVALID_LIQUIDATION_STEP));
        IMidnightModule(address(proxy)).setWithdrawalQueue(queueId, address(loanToken), steps);
    }

    function testRegistryRejectionAndQueueRevert() public {
        LiquidationAdapterHarness adapter = new LiquidationAdapterHarness(loanToken);
        loanToken.mint(address(adapter), 10 ether);
        _setAdapterQueue(adapter, 0, 0);
        registry.setRejected(address(adapter), LiquidationAdapterHarness.liquidate.selector, true);
        Market memory market = _market();
        (Offer memory sellOffer, bytes memory ratifierData) = _ratifiedSellOfferFromAlice(market);
        bytes memory buyData = abi.encode(_buyData(market, 0));
        uint256 registryRejectionNonce = proxy.nonce();
        vm.expectRevert(bytes("REGISTRY_REJECTED"));
        _executeTakeOfferWithNonce(
            sellOffer, ratifierData, 10 ether, address(0), address(proxy), buyData, registryRejectionNonce
        );

        registry.setRejected(address(adapter), LiquidationAdapterHarness.liquidate.selector, false);
        RevertingLiquidationAdapter revertingAdapter = new RevertingLiquidationAdapter();
        IMidnightModule.WithdrawalStep[] memory steps = new IMidnightModule.WithdrawalStep[](1);
        steps[0] = _rawCallStep(
            address(revertingAdapter),
            abi.encodeWithSelector(RevertingLiquidationAdapter.liquidate.selector, uint256(0), address(proxy)),
            4,
            0
        );
        _setDefaultQueue(steps);
        uint256 queueRevertNonce = proxy.nonce();
        vm.expectRevert(bytes(MIDNIGHT_LIQUIDATION_CALL_FAILED));
        _executeTakeOfferWithNonce(
            sellOffer, ratifierData, 10 ether, address(0), address(proxy), buyData, queueRevertNonce
        );
    }

    function testMinFinalBalanceAndUnauthorizedConfigRevert() public {
        loanToken.mint(address(proxy), 10 ether);
        IMidnightModule(address(proxy)).setIdleLiquidityCap(address(loanToken), 10 ether);
        Market memory market = _market();
        (Offer memory sellOffer, bytes memory ratifierData) = _ratifiedSellOfferFromAlice(market);
        bytes memory buyData = abi.encode(_buyData(market, 20 ether));
        uint256 minFinalNonce = proxy.nonce();
        vm.expectRevert(bytes(MIDNIGHT_INSUFFICIENT_LIQUIDITY));
        _executeTakeOfferWithNonce(sellOffer, ratifierData, 5 ether, address(0), address(proxy), buyData, minFinalNonce);

        vm.prank(alice);
        vm.expectRevert();
        IMidnightModule(address(proxy)).setIdleLiquidityCap(address(loanToken), 1);
    }

    function testOnBuyCanSelectNamedWithdrawalQueueFromCallbackData() public {
        LiquidationAdapterHarness defaultAdapter = new LiquidationAdapterHarness(loanToken);
        _setAdapterQueue(defaultAdapter, 0, 0);

        LiquidationAdapterHarness namedAdapter = new LiquidationAdapterHarness(loanToken);
        loanToken.mint(address(namedAdapter), 25 ether);
        bytes32 namedQueueId = keccak256("vault.queue");
        IMidnightModule.WithdrawalStep[] memory steps = new IMidnightModule.WithdrawalStep[](1);
        steps[0] = _adapterStep(namedAdapter, 0, 0);
        IMidnightModule(address(proxy)).setWithdrawalQueue(namedQueueId, address(loanToken), steps);

        Market memory market = _market();
        (Offer memory offer, bytes memory ratifierData) = _ratifiedSellOfferFromAlice(market);
        IMidnightModule.BuyCallbackData memory data = IMidnightModule.BuyCallbackData({
            expectedMarketId: IMidnight(midnight).toId(market),
            withdrawalQueueId: namedQueueId,
            minFinalLoanTokenBalance: 0
        });

        _executeTakeOffer(offer, ratifierData, 25 ether, address(0), address(proxy), abi.encode(data));

        assertEq(loanToken.balanceOf(address(namedAdapter)), 0);
        assertEq(loanToken.balanceOf(address(defaultAdapter)), 0);
        assertEq(loanToken.balanceOf(alice), INITIAL_BALANCE + 25 ether);
    }

    function testWithdrawalQueueAdapterModeAvoidsRawCalldataPlaceholder() public {
        LiquidationAdapterHarness adapter = new LiquidationAdapterHarness(loanToken);
        loanToken.mint(address(adapter), 15 ether);
        _setAdapterQueue(adapter, 0, 0);

        Market memory market = _market();
        (Offer memory offer, bytes memory ratifierData) = _ratifiedSellOfferFromAlice(market);
        _executeTakeOffer(offer, ratifierData, 15 ether, address(0), address(proxy), abi.encode(_buyData(market, 0)));

        assertEq(loanToken.balanceOf(address(adapter)), 0);
        assertEq(loanToken.balanceOf(alice), INITIAL_BALANCE + 15 ether);
    }

    function testSellCallbackMinFinalBalanceGuard() public {
        Market memory market = _market();
        bytes32 id = IMidnight(midnight).toId(market);
        bytes memory data = abi.encode(
            IMidnightModule.SellCallbackData({
                expectedMarketId: id, expectedReceiver: bob, minFinalLoanTokenBalance: 5 ether
            })
        );

        vm.prank(midnight);
        vm.expectRevert(bytes(MIDNIGHT_INSUFFICIENT_LIQUIDITY));
        IMidnightModule(address(proxy)).onSell(id, market, 1 ether, 1 ether, 0, address(proxy), bob, data);

        loanToken.mint(address(proxy), 5 ether);
        vm.prank(midnight);
        bytes32 result =
            IMidnightModule(address(proxy)).onSell(id, market, 1 ether, 1 ether, 0, address(proxy), bob, data);
        assertEq(result, midnightModule.CALLBACK_SUCCESS());
    }

    function testHookInvalidInactiveAndInsufficientOutputReverts() public {
        vm.expectRevert(bytes(HOOKMIDNIGHT_INVALID_HOOK_DATA));
        midnightHook.buildExecutions(
            address(0),
            abi.encode(
                MidnightHook.HookData({
                    action: MidnightHook.Action.WithdrawCredits,
                    actionData: abi.encode(
                        MidnightHook.WithdrawCreditsData({
                            midnight: address(0), market: _market(), units: 1, receiver: bob
                        })
                    ),
                    minAmountOut: 0
                })
            )
        );

        vm.prank(address(proxy));
        vm.expectRevert(bytes(HOOKMIDNIGHT_INACTIVE_CONTEXT));
        midnightHook.snapshotBalance(address(loanToken), bob);

        Market memory withdrawMarket = _market();
        _createRepaidWalletCredit(withdrawMarket, 5 ether);
        IHookExecution.HookExecution[] memory withdrawHooks = new IHookExecution.HookExecution[](1);
        withdrawHooks[0] = IHookExecution.HookExecution({
            hookId: MIDNIGHT_HOOK_ID,
            data: abi.encode(
                MidnightHook.HookData({
                    action: MidnightHook.Action.WithdrawCredits,
                    actionData: abi.encode(
                        MidnightHook.WithdrawCreditsData({
                            midnight: midnight, market: withdrawMarket, units: 5 ether, receiver: bob
                        })
                    ),
                    minAmountOut: 6 ether
                })
            )
        });
        uint256 withdrawNonce = proxy.nonce();
        vm.expectRevert(bytes(HOOKMIDNIGHT_INSUFFICIENT_OUTPUT));
        proxy.executeWithHookExecution(withdrawNonce, block.timestamp + 1, withdrawHooks);

        Market memory takeMarket = _market();
        _createWalletCredit(takeMarket, 1 ether);
        (Offer memory offer, bytes memory ratifierData) = _ratifiedBuyOfferFromAlice(takeMarket);
        IHookExecution.HookExecution[] memory takeHooks = new IHookExecution.HookExecution[](1);
        takeHooks[0] = IHookExecution.HookExecution({
            hookId: MIDNIGHT_HOOK_ID,
            data: abi.encode(
                MidnightHook.HookData({
                    action: MidnightHook.Action.TakeOffer,
                    actionData: abi.encode(
                        MidnightHook.TakeOfferData({
                            midnight: midnight,
                            offer: offer,
                            ratifierData: ratifierData,
                            units: 1 ether,
                            receiverIfTakerIsSeller: address(proxy),
                            takerCallback: address(0),
                            takerCallbackData: ""
                        })
                    ),
                    minAmountOut: 2 ether
                })
            )
        });
        uint256 takeNonce = proxy.nonce();
        vm.expectRevert(bytes(HOOKMIDNIGHT_INSUFFICIENT_OUTPUT));
        proxy.executeWithHookExecution(takeNonce, block.timestamp + 1, takeHooks);
    }

    function _market() internal view returns (Market memory market) {
        CollateralParams[] memory collateralParams = new CollateralParams[](1);
        collateralParams[0] =
            CollateralParams({ token: address(collateralToken), lltv: WAD, maxLif: WAD, oracle: address(oracle) });
        market = Market({
            loanToken: address(loanToken),
            collateralParams: collateralParams,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    function _buyData(
        Market memory market,
        uint256 minFinal
    )
        internal
        view
        returns (IMidnightModule.BuyCallbackData memory)
    {
        return _buyDataWithId(IMidnight(midnight).toId(market), minFinal);
    }

    function _buyDataWithId(
        bytes32 id,
        uint256 minFinal
    )
        internal
        pure
        returns (IMidnightModule.BuyCallbackData memory)
    {
        return IMidnightModule.BuyCallbackData({
            expectedMarketId: id, withdrawalQueueId: bytes32(0), minFinalLoanTokenBalance: minFinal
        });
    }

    function _sellOfferFromAlice(Market memory market) internal view returns (Offer memory offer) {
        offer = Offer({
            market: market,
            buy: false,
            maker: alice,
            start: block.timestamp,
            expiry: block.timestamp + 1 days,
            tick: MAX_TICK,
            group: bytes32(0),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: alice,
            ratifier: ratifier,
            reduceOnly: false,
            maxUnits: type(uint256).max,
            maxAssets: 0
        });
    }

    function _buyOfferFromAlice(Market memory market) internal view returns (Offer memory offer) {
        offer = Offer({
            market: market,
            buy: true,
            maker: alice,
            start: block.timestamp,
            expiry: block.timestamp + 1 days,
            tick: MAX_TICK,
            group: bytes32(0),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: ratifier,
            reduceOnly: false,
            maxUnits: type(uint256).max,
            maxAssets: 0
        });
    }

    function _buyOfferFromBob(Market memory market, uint256 tick) internal view returns (Offer memory offer) {
        offer = Offer({
            market: market,
            buy: true,
            maker: bob,
            start: block.timestamp,
            expiry: block.timestamp + 1 days,
            tick: tick,
            group: bytes32(0),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: ratifier,
            reduceOnly: false,
            maxUnits: type(uint256).max,
            maxAssets: 0
        });
    }

    function _buyOfferFromWallet(Market memory market, uint256 tick) internal view returns (Offer memory offer) {
        offer = Offer({
            market: market,
            buy: true,
            maker: address(proxy),
            start: block.timestamp,
            expiry: block.timestamp + 1 days,
            tick: tick,
            group: bytes32(0),
            callback: address(proxy),
            callbackData: abi.encode(_buyData(market, 0)),
            receiverIfMakerIsSeller: address(0),
            ratifier: ratifier,
            reduceOnly: false,
            maxUnits: type(uint256).max,
            maxAssets: 0
        });
    }

    function _sellOfferFromWallet(Market memory market, address receiver) internal view returns (Offer memory offer) {
        offer = Offer({
            market: market,
            buy: false,
            maker: address(proxy),
            start: block.timestamp,
            expiry: block.timestamp + 1 days,
            tick: MAX_TICK,
            group: bytes32(0),
            callback: address(proxy),
            callbackData: abi.encode(
                IMidnightModule.SellCallbackData({
                    expectedMarketId: IMidnight(midnight).toId(market),
                    expectedReceiver: receiver,
                    minFinalLoanTokenBalance: 0
                })
            ),
            receiverIfMakerIsSeller: receiver,
            ratifier: ratifier,
            reduceOnly: true,
            maxUnits: type(uint256).max,
            maxAssets: 0
        });
    }

    function _ratifiedSellOfferFromAlice(Market memory market)
        internal
        returns (Offer memory offer, bytes memory data)
    {
        _collateralizeAlice(market, 1_000_000 ether);
        offer = _sellOfferFromAlice(market);
        data = _ratifyAliceOffer(offer);
    }

    function _ratifiedBuyOfferFromAlice(Market memory market) internal returns (Offer memory offer, bytes memory data) {
        offer = _buyOfferFromAlice(market);
        data = _ratifyAliceOffer(offer);
    }

    function _ratifiedSellOfferFromWallet(
        Market memory market,
        address receiver
    )
        internal
        returns (Offer memory offer, bytes memory data)
    {
        offer = _sellOfferFromWallet(market, receiver);
        data = _ratifyWalletOffer(offer);
    }

    function _createWalletCredit(Market memory market, uint256 units) internal {
        loanToken.mint(address(proxy), units);
        (Offer memory offer, bytes memory ratifierData) = _ratifiedSellOfferFromAlice(market);
        _executeTakeOffer(offer, ratifierData, units, address(0), address(proxy), abi.encode(_buyData(market, 0)));
    }

    function _depositWalletAssetsIntoVault(BasicERC4626Vault vault, uint256 assets) internal {
        ERC4626ApproveAndDepositHook depositHook = new ERC4626ApproveAndDepositHook(address(proxy));
        vm.prank(address(proxy));
        depositHook.setVaultAllowed(address(vault), true);
        proxy.installHook(DEPOSIT_HOOK_ID, address(depositHook));

        IHookExecution.HookExecution[] memory hooks = new IHookExecution.HookExecution[](1);
        hooks[0] = IHookExecution.HookExecution({
            hookId: DEPOSIT_HOOK_ID,
            data: abi.encode(
                ERC4626ApproveAndDepositHook.ApproveAndDepositData({
                    vault: address(vault), assets: assets, receiver: address(proxy), minShares: assets
                })
            )
        });
        proxy.executeWithHookExecution(proxy.nonce(), block.timestamp + 1, hooks);
    }

    function _createRepaidWalletCredit(Market memory market, uint256 units) internal {
        _createWalletCredit(market, units);
        vm.prank(alice);
        IMidnightRuntime(midnight).repay(market, units, alice, address(0), "");
    }

    function _collateralizeAlice(Market memory market, uint256 assets) internal {
        collateralToken.mint(alice, assets);
        vm.prank(alice);
        IMidnightRuntime(midnight).supplyCollateral(market, 0, assets, alice);
    }

    function _ratifyAliceOffer(Offer memory offer) internal returns (bytes memory data) {
        bytes32 root = _hashOffer(offer);
        vm.prank(alice);
        ISetterRatifierRuntime(ratifier).setIsRootRatified(alice, root, true);
        data = _encodeSingleLeafProof(root);
    }

    function _ratifyBobOffer(Offer memory offer) internal returns (bytes memory data) {
        bytes32 root = _hashOffer(offer);
        vm.prank(bob);
        ISetterRatifierRuntime(ratifier).setIsRootRatified(bob, root, true);
        data = _encodeSingleLeafProof(root);
    }

    function _ratifyWalletOffer(Offer memory offer) internal returns (bytes memory data) {
        bytes32 root = _hashOffer(offer);
        _executeRatifyOfferRoot(root, true);
        data = _encodeSingleLeafProof(root);
    }

    function _encodeSingleLeafProof(bytes32 root) internal pure returns (bytes memory) {
        return abi.encode(root, uint256(0), new bytes32[](0));
    }

    function _hashOffer(Offer memory offer) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                OFFER_TYPEHASH,
                _hashMarket(offer.market),
                offer.buy,
                offer.maker,
                offer.start,
                offer.expiry,
                offer.tick,
                offer.group,
                offer.callback,
                keccak256(offer.callbackData),
                offer.receiverIfMakerIsSeller,
                offer.ratifier,
                offer.reduceOnly,
                offer.maxUnits,
                offer.maxAssets
            )
        );
    }

    function _hashMarket(Market memory market) internal pure returns (bytes32) {
        bytes32[] memory collateralParamsHashes = new bytes32[](market.collateralParams.length);
        for (uint256 i; i < market.collateralParams.length; ++i) {
            collateralParamsHashes[i] = _hashCollateralParams(market.collateralParams[i]);
        }

        bytes32 collateralParamsHash;
        assembly ("memory-safe") {
            collateralParamsHash := keccak256(
                add(collateralParamsHashes, 0x20),
                mul(mload(collateralParamsHashes), 0x20)
            )
        }

        return keccak256(
            abi.encode(
                MARKET_TYPEHASH,
                market.loanToken,
                collateralParamsHash,
                market.maturity,
                market.rcfThreshold,
                market.enterGate,
                market.liquidatorGate
            )
        );
    }

    function _hashCollateralParams(CollateralParams memory collateralParams) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                COLLATERAL_PARAMS_TYPEHASH,
                collateralParams.token,
                collateralParams.lltv,
                collateralParams.maxLif,
                collateralParams.oracle
            )
        );
    }

    function _adapterStep(
        LiquidationAdapterHarness adapter,
        uint256 maxAmount,
        uint256 minOutput
    )
        internal
        view
        returns (IMidnightModule.WithdrawalStep memory)
    {
        return IMidnightModule.WithdrawalStep({
            kind: IMidnightModule.WithdrawalStepKind.Adapter,
            target: address(adapter),
            value: 0,
            callData: "",
            amountPlaceholderOffset: 0,
            maxWithdrawAssets: maxAmount == 0 ? type(uint128).max : maxAmount,
            minLoanTokenOut: minOutput,
            expectedOutputToken: address(loanToken)
        });
    }

    function _rawCallStep(
        address target,
        bytes memory callData,
        uint256 placeholderOffset,
        uint256 minOutput
    )
        internal
        view
        returns (IMidnightModule.WithdrawalStep memory)
    {
        return IMidnightModule.WithdrawalStep({
            kind: IMidnightModule.WithdrawalStepKind.RawCall,
            target: target,
            value: 0,
            callData: callData,
            amountPlaceholderOffset: placeholderOffset,
            maxWithdrawAssets: type(uint128).max,
            minLoanTokenOut: minOutput,
            expectedOutputToken: address(loanToken)
        });
    }

    function _setDefaultQueue(IMidnightModule.WithdrawalStep[] memory steps) internal {
        IMidnightModule(address(proxy))
            .setWithdrawalQueue(
                IMidnightModule(address(proxy)).loanTokenQueueId(address(loanToken)), address(loanToken), steps
            );
    }

    function _setAdapterQueue(LiquidationAdapterHarness adapter, uint256 maxAmount, uint256 minOutput) internal {
        IMidnightModule.WithdrawalStep[] memory steps = new IMidnightModule.WithdrawalStep[](1);
        steps[0] = _adapterStep(adapter, maxAmount, minOutput);
        _setDefaultQueue(steps);
    }

    function _setTwoAdapterQueue(LiquidationAdapterHarness first, LiquidationAdapterHarness second) internal {
        IMidnightModule.WithdrawalStep[] memory steps = new IMidnightModule.WithdrawalStep[](2);
        steps[0] = _adapterStep(first, type(uint128).max, 0);
        steps[1] = _adapterStep(second, type(uint128).max, 0);
        _setDefaultQueue(steps);
    }

    function _setVaultQueue(QueueVaultHarness vault, uint256 minOutput) internal {
        IMidnightModule.WithdrawalStep[] memory steps = new IMidnightModule.WithdrawalStep[](1);
        steps[0] = _rawCallStep(
            address(vault),
            abi.encodeWithSelector(QueueVaultHarness.withdraw.selector, uint256(0), address(proxy), address(proxy)),
            4,
            minOutput
        );
        _setDefaultQueue(steps);
    }

    function _setBasicVaultQueue(BasicERC4626Vault vault, uint256 minOutput) internal {
        IMidnightModule.WithdrawalStep[] memory steps = new IMidnightModule.WithdrawalStep[](1);
        steps[0] = _rawCallStep(
            address(vault),
            abi.encodeWithSelector(BasicERC4626Vault.withdraw.selector, uint256(0), address(proxy), address(proxy)),
            4,
            minOutput
        );
        _setDefaultQueue(steps);
    }
}
