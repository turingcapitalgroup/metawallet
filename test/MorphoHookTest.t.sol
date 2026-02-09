// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Test Base
import { BaseTest } from "metawallet/test/base/BaseTest.t.sol";

// External Libraries
import { MinimalUUPSFactory } from "minimal-uups-factory/MinimalUUPSFactory.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

// Local Contracts
import { MetaWallet, MinimalSmartAccount } from "metawallet/src/MetaWallet.sol";
import { USDC_MAINNET, _1_USDC } from "metawallet/src/helpers/AddressBook.sol";
import { MorphoSupplyHook } from "metawallet/src/hooks/MorphoSupplyHook.sol";
import { MorphoWithdrawHook } from "metawallet/src/hooks/MorphoWithdrawHook.sol";

// Morpho Blue
import { IMorpho, Market, MarketParams } from "morpho-blue/interfaces/IMorpho.sol";
import { MarketParamsLib } from "morpho-blue/libraries/MarketParamsLib.sol";

// Local Interfaces
import { IERC20 } from "metawallet/src/interfaces/IERC20.sol";
import { IHookExecution } from "metawallet/src/interfaces/IHookExecution.sol";
import { IMetaWallet } from "metawallet/src/interfaces/IMetaWallet.sol";

// Mock Contracts
import { MockRegistry } from "metawallet/test/helpers/mocks/MockRegistry.sol";

// Errors
import "metawallet/src/errors/Errors.sol" as Errors;

contract MorphoHookTest is BaseTest {
    using SafeTransferLib for address;
    using MarketParamsLib for MarketParams;

    /* ///////////////////////////////////////////////////////////////
                              CONTRACTS
    ///////////////////////////////////////////////////////////////*/

    IMetaWallet public metaWallet;
    MinimalUUPSFactory public proxyFactory;
    MorphoSupplyHook public supplyHook;
    MorphoWithdrawHook public withdrawHook;
    MockRegistry public registry;

    /* ///////////////////////////////////////////////////////////////
                              CONSTANTS
    ///////////////////////////////////////////////////////////////*/

    uint256 public constant INITIAL_BALANCE = 100_000 * _1_USDC;
    uint256 public constant SUPPLY_AMOUNT = 1000 * _1_USDC;

    bytes32 public constant SUPPLY_HOOK_ID = keccak256("hook.morpho.supply");
    bytes32 public constant WITHDRAW_HOOK_ID = keccak256("hook.morpho.withdraw");

    // Morpho Blue singleton on mainnet
    address public constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    // wstETH/USDC market (86% LLTV) — one of the largest USDC supply markets on Morpho Blue
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant MORPHO_ORACLE = 0x48F7E36EB6B826B2dF4B2E630B62Cd25e89E40e2;
    address public constant ADAPTIVE_CURVE_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 public constant LLTV_86 = 860_000_000_000_000_000;

    MarketParams public marketParams;

    /* ///////////////////////////////////////////////////////////////
                              SETUP
    ///////////////////////////////////////////////////////////////*/

    function setUp() public {
        _setUp("MAINNET", 23_783_139);
        vm.stopPrank();

        // Build market params
        marketParams = MarketParams({
            loanToken: USDC_MAINNET,
            collateralToken: WSTETH,
            oracle: MORPHO_ORACLE,
            irm: ADAPTIVE_CURVE_IRM,
            lltv: LLTV_86
        });

        // Sanity check: market must exist on fork
        Market memory m = IMorpho(MORPHO).market(marketParams.id());
        require(m.totalSupplyAssets > 0, "Market does not exist on fork");

        // Deploy registry
        registry = new MockRegistry();

        // Deploy proxy factory and MetaWallet
        proxyFactory = new MinimalUUPSFactory();
        MetaWallet _impl = new MetaWallet();

        bytes memory _initData = abi.encodeWithSelector(
            MinimalSmartAccount.initialize.selector, users.owner, address(registry), "metawallet.morpho.1.0"
        );
        address _proxy = proxyFactory.deployAndCall(address(_impl), _initData);

        // Grant roles
        vm.startPrank(users.owner);
        MetaWallet(payable(_proxy)).grantRoles(users.admin, 1);
        MetaWallet(payable(_proxy)).grantRoles(users.owner, 2);
        vm.stopPrank();

        metaWallet = IMetaWallet(_proxy);

        // Deploy hooks
        supplyHook = new MorphoSupplyHook(address(metaWallet));
        withdrawHook = new MorphoWithdrawHook(address(metaWallet));

        // Install hooks
        vm.startPrank(users.admin);
        MetaWallet(payable(address(metaWallet))).installHook(SUPPLY_HOOK_ID, address(supplyHook));
        MetaWallet(payable(address(metaWallet))).installHook(WITHDRAW_HOOK_ID, address(withdrawHook));
        vm.stopPrank();

        // Whitelist targets in registry
        registry.whitelistTarget(address(supplyHook));
        registry.whitelistTarget(address(withdrawHook));
        registry.whitelistTarget(USDC_MAINNET);
        registry.whitelistTarget(MORPHO);

        // Fund the wallet with USDC
        deal(USDC_MAINNET, address(metaWallet), INITIAL_BALANCE);

        // Labels
        vm.label(address(supplyHook), "MorphoSupplyHook");
        vm.label(address(withdrawHook), "MorphoWithdrawHook");
        vm.label(address(metaWallet), "MetaWallet");
        vm.label(MORPHO, "Morpho");
        vm.label(USDC_MAINNET, "USDC");
        vm.label(WSTETH, "wstETH");
    }

    /* ///////////////////////////////////////////////////////////////
                    SUPPLY HOOK — STATIC AMOUNT TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_Supply_StaticAmount() public {
        uint256 _usdcBefore = IERC20(USDC_MAINNET).balanceOf(address(metaWallet));

        _executeSupply(SUPPLY_AMOUNT, 0);

        uint256 _usdcAfter = IERC20(USDC_MAINNET).balanceOf(address(metaWallet));
        assertEq(_usdcBefore - _usdcAfter, SUPPLY_AMOUNT, "Wallet should spend exact USDC");

        // Verify position was credited
        uint256 _shares = supplyHook.getSupplyPosition(MORPHO, marketParams, address(metaWallet));
        assertGt(_shares, 0, "Wallet should have supply shares");
    }

    function test_Supply_ApprovalResetAfterExecution() public {
        _executeSupply(SUPPLY_AMOUNT, 0);

        uint256 _allowance = IERC20(USDC_MAINNET).allowance(address(supplyHook), MORPHO);
        assertEq(_allowance, 0, "USDC approval from hook to Morpho should be reset to 0");
    }

    function test_Supply_ContextCleanup() public {
        _executeSupply(SUPPLY_AMOUNT, 0);

        assertFalse(supplyHook.hasActiveContext(), "Context should be cleaned up");
        assertEq(supplyHook.getOutputAmount(), 0, "Output should be 0 after cleanup");
    }

    function test_Supply_SlippageProtection() public {
        uint256 _expectedShares = supplyHook.previewSupplyShares(MORPHO, marketParams, SUPPLY_AMOUNT);
        uint256 _minShares = _expectedShares * 99 / 100;

        _executeSupply(SUPPLY_AMOUNT, _minShares);

        uint256 _shares = supplyHook.getSupplyPosition(MORPHO, marketParams, address(metaWallet));
        assertGe(_shares, _minShares, "Should receive at least minShares");
    }

    function testRevert_Supply_SlippageExceeded() public {
        MorphoSupplyHook.SupplyData memory _data = MorphoSupplyHook.SupplyData({
            morpho: MORPHO,
            marketParams: marketParams,
            assets: SUPPLY_AMOUNT,
            onBehalf: address(metaWallet),
            minShares: type(uint256).max
        });

        IHookExecution.HookExecution[] memory _hooks = new IHookExecution.HookExecution[](1);
        _hooks[0] = IHookExecution.HookExecution({ hookId: SUPPLY_HOOK_ID, data: abi.encode(_data) });

        vm.prank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKMORPHOSUPPLY_INSUFFICIENT_SHARES));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hooks);
    }

    function testRevert_Supply_ZeroAssets() public {
        MorphoSupplyHook.SupplyData memory _data = MorphoSupplyHook.SupplyData({
            morpho: MORPHO, marketParams: marketParams, assets: 0, onBehalf: address(metaWallet), minShares: 0
        });

        IHookExecution.HookExecution[] memory _hooks = new IHookExecution.HookExecution[](1);
        _hooks[0] = IHookExecution.HookExecution({ hookId: SUPPLY_HOOK_ID, data: abi.encode(_data) });

        vm.prank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKMORPHOSUPPLY_INVALID_HOOK_DATA));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hooks);
    }

    /* ///////////////////////////////////////////////////////////////
                    WITHDRAW HOOK — ASSET-BASED TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_Withdraw_StaticAssetBased() public {
        _executeSupply(SUPPLY_AMOUNT, 0);

        uint256 _usdcBefore = IERC20(USDC_MAINNET).balanceOf(address(metaWallet));
        uint256 _withdrawAmount = 500 * _1_USDC;

        _executeWithdrawByAssets(_withdrawAmount, 0);

        uint256 _usdcAfter = IERC20(USDC_MAINNET).balanceOf(address(metaWallet));
        assertEq(_usdcAfter - _usdcBefore, _withdrawAmount, "Should receive exact assets requested");
    }

    /* ///////////////////////////////////////////////////////////////
                    WITHDRAW HOOK — SHARES-BASED TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_Withdraw_StaticSharesBased_FullExit() public {
        _executeSupply(SUPPLY_AMOUNT, 0);

        // Get exact share balance
        uint256 _shares = supplyHook.getSupplyPosition(MORPHO, marketParams, address(metaWallet));
        assertGt(_shares, 0, "Should have shares to withdraw");

        uint256 _usdcBefore = IERC20(USDC_MAINNET).balanceOf(address(metaWallet));

        _executeWithdrawByShares(_shares, 0);

        uint256 _usdcAfter = IERC20(USDC_MAINNET).balanceOf(address(metaWallet));
        assertGt(_usdcAfter, _usdcBefore, "Should receive USDC");

        // Position should be fully exited (no dust)
        uint256 _sharesAfter = supplyHook.getSupplyPosition(MORPHO, marketParams, address(metaWallet));
        assertEq(_sharesAfter, 0, "Shares-based exit should leave zero dust");
    }

    function test_Withdraw_SharesBased_PartialExit() public {
        _executeSupply(SUPPLY_AMOUNT, 0);

        uint256 _totalShares = supplyHook.getSupplyPosition(MORPHO, marketParams, address(metaWallet));
        uint256 _halfShares = _totalShares / 2;

        _executeWithdrawByShares(_halfShares, 0);

        uint256 _remainingShares = supplyHook.getSupplyPosition(MORPHO, marketParams, address(metaWallet));
        assertEq(_remainingShares, _totalShares - _halfShares, "Should have remaining shares");
    }

    function testRevert_Withdraw_ZeroAssetsAndShares() public {
        MorphoWithdrawHook.WithdrawData memory _data = MorphoWithdrawHook.WithdrawData({
            morpho: MORPHO,
            marketParams: marketParams,
            assets: 0,
            shares: 0,
            onBehalf: address(metaWallet),
            receiver: address(metaWallet),
            minAssets: 0
        });

        IHookExecution.HookExecution[] memory _hooks = new IHookExecution.HookExecution[](1);
        _hooks[0] = IHookExecution.HookExecution({ hookId: WITHDRAW_HOOK_ID, data: abi.encode(_data) });

        vm.prank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKMORPHOWITHDRAW_INVALID_HOOK_DATA));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hooks);
    }

    /* ///////////////////////////////////////////////////////////////
                    SUPPLY → WITHDRAW DYNAMIC CHAIN
    ///////////////////////////////////////////////////////////////*/

    function test_SupplyThenWithdraw_FullRoundTrip() public {
        // Supply static amount, then withdraw all shares to fully exit
        _executeSupply(SUPPLY_AMOUNT, 0);

        uint256 _shares = supplyHook.getSupplyPosition(MORPHO, marketParams, address(metaWallet));
        assertGt(_shares, 0, "Should have supply shares");

        uint256 _usdcBefore = IERC20(USDC_MAINNET).balanceOf(address(metaWallet));

        // Withdraw by shares for full exit (no dust)
        _executeWithdrawByShares(_shares, 0);

        uint256 _usdcAfter = IERC20(USDC_MAINNET).balanceOf(address(metaWallet));
        uint256 _sharesAfter = supplyHook.getSupplyPosition(MORPHO, marketParams, address(metaWallet));

        assertEq(_sharesAfter, 0, "Should have zero shares after full exit");
        assertApproxEqAbs(_usdcAfter - _usdcBefore, SUPPLY_AMOUNT, 2, "Should recover ~all USDC");
    }

    /* ///////////////////////////////////////////////////////////////
                    PREVIEW / POSITION VIEW FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    function test_PreviewSupplyShares_ReasonableEstimate() public {
        uint256 _previewShares = supplyHook.previewSupplyShares(MORPHO, marketParams, SUPPLY_AMOUNT);
        assertGt(_previewShares, 0, "Preview should return non-zero shares");

        // Execute and compare
        _executeSupply(SUPPLY_AMOUNT, 0);
        uint256 _actualShares = supplyHook.getSupplyPosition(MORPHO, marketParams, address(metaWallet));

        // Preview should be very close to actual (within 0.1%)
        assertApproxEqRel(_previewShares, _actualShares, 0.001 ether, "Preview should closely match actual shares");
    }

    function test_PreviewWithdrawAssets_ReasonableEstimate() public {
        _executeSupply(SUPPLY_AMOUNT, 0);

        uint256 _shares = supplyHook.getSupplyPosition(MORPHO, marketParams, address(metaWallet));
        uint256 _previewAssets = withdrawHook.previewWithdrawAssets(MORPHO, marketParams, _shares);

        assertGt(_previewAssets, 0, "Preview should return non-zero assets");
        // For a supply-only position, the preview should be close to the original amount
        assertApproxEqRel(
            _previewAssets, SUPPLY_AMOUNT, 0.01 ether, "Preview assets should be close to supplied amount"
        );
    }

    function test_GetSupplyPosition_ZeroBeforeSupply() public view {
        uint256 _shares = supplyHook.getSupplyPosition(MORPHO, marketParams, address(metaWallet));
        assertEq(_shares, 0, "Position should be zero before supply");
    }

    function test_GetSupplyPosition_NonZeroAfterSupply() public {
        _executeSupply(SUPPLY_AMOUNT, 0);

        uint256 _supplyShares = supplyHook.getSupplyPosition(MORPHO, marketParams, address(metaWallet));
        uint256 _withdrawShares = withdrawHook.getSupplyPosition(MORPHO, marketParams, address(metaWallet));

        assertGt(_supplyShares, 0, "Supply hook should see non-zero position");
        assertEq(_supplyShares, _withdrawShares, "Both hooks should return same position");
    }

    /* ///////////////////////////////////////////////////////////////
                    WITHDRAW SLIPPAGE PROTECTION
    ///////////////////////////////////////////////////////////////*/

    function test_Withdraw_SlippageProtection_AssetBased() public {
        _executeSupply(SUPPLY_AMOUNT, 0);

        uint256 _withdrawAmount = 500 * _1_USDC;
        // Use a reasonable minAssets (99% of requested)
        uint256 _minAssets = _withdrawAmount * 99 / 100;

        _executeWithdrawByAssets(_withdrawAmount, _minAssets);

        uint256 _shares = supplyHook.getSupplyPosition(MORPHO, marketParams, address(metaWallet));
        assertGt(_shares, 0, "Should still have remaining shares");
    }

    function testRevert_Withdraw_SlippageExceeded() public {
        _executeSupply(SUPPLY_AMOUNT, 0);

        MorphoWithdrawHook.WithdrawData memory _data = MorphoWithdrawHook.WithdrawData({
            morpho: MORPHO,
            marketParams: marketParams,
            assets: 500 * _1_USDC,
            shares: 0,
            onBehalf: address(metaWallet),
            receiver: address(metaWallet),
            minAssets: type(uint256).max
        });

        IHookExecution.HookExecution[] memory _hooks = new IHookExecution.HookExecution[](1);
        _hooks[0] = IHookExecution.HookExecution({ hookId: WITHDRAW_HOOK_ID, data: abi.encode(_data) });

        vm.prank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKMORPHOWITHDRAW_INSUFFICIENT_ASSETS));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hooks);
    }

    /* ///////////////////////////////////////////////////////////////
                    CONTEXT & CLEANUP TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_Withdraw_ContextCleanup() public {
        _executeSupply(SUPPLY_AMOUNT, 0);
        _executeWithdrawByAssets(500 * _1_USDC, 0);

        assertFalse(withdrawHook.hasActiveContext(), "Withdraw context should be cleaned up");
        assertEq(withdrawHook.getOutputAmount(), 0, "Withdraw output should be 0 after cleanup");
    }

    function test_Sequential_SupplyWithdrawSupply_NoStateCorruption() public {
        // First supply
        _executeSupply(SUPPLY_AMOUNT, 0);
        uint256 _shares1 = supplyHook.getSupplyPosition(MORPHO, marketParams, address(metaWallet));
        assertGt(_shares1, 0);

        // Withdraw all by shares
        _executeWithdrawByShares(_shares1, 0);
        uint256 _sharesAfterWithdraw = supplyHook.getSupplyPosition(MORPHO, marketParams, address(metaWallet));
        assertEq(_sharesAfterWithdraw, 0, "Should have no shares after full withdrawal");

        // Second supply
        _executeSupply(SUPPLY_AMOUNT, 0);
        uint256 _shares2 = supplyHook.getSupplyPosition(MORPHO, marketParams, address(metaWallet));
        assertGt(_shares2, 0, "Should have shares after second supply");
    }

    /* ///////////////////////////////////////////////////////////////
                    ERROR CASE TESTS
    ///////////////////////////////////////////////////////////////*/

    function testRevert_Supply_DynamicNoPreviousHook() public {
        MorphoSupplyHook.SupplyData memory _data = MorphoSupplyHook.SupplyData({
            morpho: MORPHO,
            marketParams: marketParams,
            assets: supplyHook.USE_PREVIOUS_HOOK_OUTPUT(),
            onBehalf: address(metaWallet),
            minShares: 0
        });

        IHookExecution.HookExecution[] memory _hooks = new IHookExecution.HookExecution[](1);
        _hooks[0] = IHookExecution.HookExecution({ hookId: SUPPLY_HOOK_ID, data: abi.encode(_data) });

        vm.prank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKMORPHOSUPPLY_PREVIOUS_HOOK_NOT_FOUND));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hooks);
    }

    function testRevert_Withdraw_DynamicNoPreviousHook() public {
        MorphoWithdrawHook.WithdrawData memory _data = MorphoWithdrawHook.WithdrawData({
            morpho: MORPHO,
            marketParams: marketParams,
            assets: withdrawHook.USE_PREVIOUS_HOOK_OUTPUT(),
            shares: 0,
            onBehalf: address(metaWallet),
            receiver: address(metaWallet),
            minAssets: 0
        });

        IHookExecution.HookExecution[] memory _hooks = new IHookExecution.HookExecution[](1);
        _hooks[0] = IHookExecution.HookExecution({ hookId: WITHDRAW_HOOK_ID, data: abi.encode(_data) });

        vm.prank(users.owner);
        vm.expectRevert(bytes(Errors.HOOKMORPHOWITHDRAW_PREVIOUS_HOOK_NOT_FOUND));
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hooks);
    }

    function testRevert_Supply_Unauthorized() public {
        MorphoSupplyHook.SupplyData memory _data = MorphoSupplyHook.SupplyData({
            morpho: MORPHO,
            marketParams: marketParams,
            assets: SUPPLY_AMOUNT,
            onBehalf: address(metaWallet),
            minShares: 0
        });

        IHookExecution.HookExecution[] memory _hooks = new IHookExecution.HookExecution[](1);
        _hooks[0] = IHookExecution.HookExecution({ hookId: SUPPLY_HOOK_ID, data: abi.encode(_data) });

        vm.prank(users.alice);
        vm.expectRevert("Unauthorized()");
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hooks);
    }

    /* ///////////////////////////////////////////////////////////////
                         HELPER FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    function _executeSupply(uint256 _amount, uint256 _minShares) internal {
        MorphoSupplyHook.SupplyData memory _data = MorphoSupplyHook.SupplyData({
            morpho: MORPHO,
            marketParams: marketParams,
            assets: _amount,
            onBehalf: address(metaWallet),
            minShares: _minShares
        });

        IHookExecution.HookExecution[] memory _hooks = new IHookExecution.HookExecution[](1);
        _hooks[0] = IHookExecution.HookExecution({ hookId: SUPPLY_HOOK_ID, data: abi.encode(_data) });

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hooks);
    }

    function _executeWithdrawByAssets(uint256 _assets, uint256 _minAssets) internal {
        MorphoWithdrawHook.WithdrawData memory _data = MorphoWithdrawHook.WithdrawData({
            morpho: MORPHO,
            marketParams: marketParams,
            assets: _assets,
            shares: 0,
            onBehalf: address(metaWallet),
            receiver: address(metaWallet),
            minAssets: _minAssets
        });

        IHookExecution.HookExecution[] memory _hooks = new IHookExecution.HookExecution[](1);
        _hooks[0] = IHookExecution.HookExecution({ hookId: WITHDRAW_HOOK_ID, data: abi.encode(_data) });

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hooks);
    }

    function _executeWithdrawByShares(uint256 _shares, uint256 _minAssets) internal {
        MorphoWithdrawHook.WithdrawData memory _data = MorphoWithdrawHook.WithdrawData({
            morpho: MORPHO,
            marketParams: marketParams,
            assets: 0,
            shares: _shares,
            onBehalf: address(metaWallet),
            receiver: address(metaWallet),
            minAssets: _minAssets
        });

        IHookExecution.HookExecution[] memory _hooks = new IHookExecution.HookExecution[](1);
        _hooks[0] = IHookExecution.HookExecution({ hookId: WITHDRAW_HOOK_ID, data: abi.encode(_data) });

        vm.prank(users.owner);
        MetaWallet(payable(address(metaWallet))).executeWithHookExecution(_hooks);
    }
}
