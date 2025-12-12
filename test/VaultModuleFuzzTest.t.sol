// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { BaseTest } from "metawallet/test/base/BaseTest.t.sol";

import { ERC1967Factory } from "solady/utils/ERC1967Factory.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { MetaWallet, MinimalSmartAccount } from "metawallet/src/MetaWallet.sol";
import { USDC_MAINNET, _1_USDC } from "metawallet/src/helpers/AddressBook.sol";
import { VaultModule } from "metawallet/src/modules/VaultModule.sol";

import { IMetaWallet } from "metawallet/src/interfaces/IMetaWallet.sol";

import { MockRegistry } from "metawallet/test/helpers/mocks/MockRegistry.sol";

contract VaultModuleFuzzTest is BaseTest {
    using SafeTransferLib for address;

    /* ///////////////////////////////////////////////////////////////
                              CONTRACTS
    ///////////////////////////////////////////////////////////////*/

    IMetaWallet public metaWallet;
    ERC1967Factory public proxyFactory;
    MockRegistry public registry;

    /* ///////////////////////////////////////////////////////////////
                              CONSTANTS
    ///////////////////////////////////////////////////////////////*/

    uint256 public constant MAX_DEPOSIT = 100_000_000 * _1_USDC; // 100M USDC
    uint256 public constant MIN_DEPOSIT = 1; // 1 wei

    uint256 public constant ADMIN_ROLE = 1;
    uint256 public constant EXECUTOR_ROLE = 2;
    uint256 public constant MANAGER_ROLE = 16;
    uint256 public constant EMERGENCY_ADMIN_ROLE = 64;

    /* ///////////////////////////////////////////////////////////////
                              SETUP
    ///////////////////////////////////////////////////////////////*/

    function setUp() public {
        _setUp("MAINNET", 23_783_139);
        vm.stopPrank();

        registry = new MockRegistry();

        proxyFactory = new ERC1967Factory();
        MetaWallet _metaWalletImplementation = new MetaWallet();

        bytes memory _initData = abi.encodeWithSelector(
            MinimalSmartAccount.initialize.selector, users.owner, address(registry), "metawallet.vault.fuzz.1.0"
        );
        address _metaWalletProxy =
            proxyFactory.deployAndCall(address(_metaWalletImplementation), users.admin, _initData);

        vm.startPrank(users.owner);
        MetaWallet(payable(_metaWalletProxy)).grantRoles(users.admin, ADMIN_ROLE);
        MetaWallet(payable(_metaWalletProxy)).grantRoles(users.owner, EXECUTOR_ROLE);
        MetaWallet(payable(_metaWalletProxy)).grantRoles(users.executor, MANAGER_ROLE);
        MetaWallet(payable(_metaWalletProxy)).grantRoles(users.charlie, EMERGENCY_ADMIN_ROLE);
        vm.stopPrank();

        VaultModule _vault = new VaultModule();
        bytes4[] memory _vaultSelectors = _vault.selectors();

        vm.startPrank(users.admin);
        MetaWallet(payable(_metaWalletProxy)).addFunctions(_vaultSelectors, address(_vault), false);
        VaultModule(_metaWalletProxy).initializeVault(address(USDC_MAINNET), "Meta USDC", "mUSDC");
        vm.stopPrank();

        metaWallet = IMetaWallet(_metaWalletProxy);

        registry.whitelistTarget(address(USDC_MAINNET));

        vm.prank(users.alice);
        USDC_MAINNET.safeApprove(address(metaWallet), type(uint256).max);

        vm.prank(users.bob);
        USDC_MAINNET.safeApprove(address(metaWallet), type(uint256).max);

        vm.label(address(metaWallet), "MetaWallet");
        vm.label(address(registry), "Registry");
        vm.label(address(USDC_MAINNET), "USDC");
    }

    /* ///////////////////////////////////////////////////////////////
                    FUZZ TEST: DEPOSIT/REDEEM ROUNDTRIP
    ///////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: deposit and full redeem should return original assets
    function testFuzz_DepositAndRedeem_Roundtrip(uint256 _depositAmount) public {
        _depositAmount = bound(_depositAmount, MIN_DEPOSIT, MAX_DEPOSIT);

        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        uint256 _shares = metaWallet.deposit(_depositAmount, users.alice);

        assertEq(metaWallet.balanceOf(users.alice), _shares, "Shares minted mismatch");
        assertEq(metaWallet.totalAssets(), _depositAmount, "TotalAssets after deposit mismatch");

        metaWallet.requestRedeem(_shares, users.alice, users.alice);
        uint256 _assetsReturned = metaWallet.redeem(_shares, users.alice, users.alice);
        vm.stopPrank();

        assertEq(_assetsReturned, _depositAmount, "Assets returned should equal deposited");
        assertEq(metaWallet.balanceOf(users.alice), 0, "User should have 0 shares after full redeem");
        assertEq(metaWallet.totalSupply(), 0, "Total supply should be 0 after full redeem");
        assertEq(metaWallet.totalAssets(), 0, "Total assets should be 0 after full redeem");
    }

    /// @notice Fuzz test: partial redeem should return proportional assets
    function testFuzz_PartialRedeem(uint256 _depositAmount, uint256 _redeemPercent) public {
        _depositAmount = bound(_depositAmount, 100, MAX_DEPOSIT); // Min 100 to avoid rounding to 0
        _redeemPercent = bound(_redeemPercent, 1, 99); // 1-99%

        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        uint256 _shares = metaWallet.deposit(_depositAmount, users.alice);

        uint256 _redeemShares = (_shares * _redeemPercent) / 100;
        if (_redeemShares == 0) _redeemShares = 1;

        metaWallet.requestRedeem(_redeemShares, users.alice, users.alice);
        uint256 _assetsReturned = metaWallet.redeem(_redeemShares, users.alice, users.alice);
        vm.stopPrank();

        uint256 _expectedAssets = (_depositAmount * _redeemPercent) / 100;

        // Allow 1 wei rounding error
        assertApproxEqAbs(_assetsReturned, _expectedAssets, 1, "Partial redeem assets mismatch");
        assertEq(metaWallet.balanceOf(users.alice), _shares - _redeemShares, "Remaining shares mismatch");
    }

    /* ///////////////////////////////////////////////////////////////
                    FUZZ TEST: SHARE PRICE STABILITY
    ///////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: share price remains stable through deposits (no yield/loss)
    function testFuzz_SharePrice_StableThroughDeposits(uint256 _deposit1, uint256 _deposit2) public {
        _deposit1 = bound(_deposit1, MIN_DEPOSIT, MAX_DEPOSIT / 2);
        _deposit2 = bound(_deposit2, MIN_DEPOSIT, MAX_DEPOSIT / 2);

        uint256 _initialSharePrice = metaWallet.sharePrice();

        // First deposit
        deal(USDC_MAINNET, users.alice, _deposit1);
        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_deposit1, users.alice, users.alice);
        metaWallet.deposit(_deposit1, users.alice);
        vm.stopPrank();

        uint256 _sharePriceAfterFirst = metaWallet.sharePrice();
        assertEq(_sharePriceAfterFirst, _initialSharePrice, "Share price changed after first deposit");

        // Second deposit
        deal(USDC_MAINNET, users.bob, _deposit2);
        vm.startPrank(users.bob);
        metaWallet.requestDeposit(_deposit2, users.bob, users.bob);
        metaWallet.deposit(_deposit2, users.bob);
        vm.stopPrank();

        uint256 _sharePriceAfterSecond = metaWallet.sharePrice();
        assertEq(_sharePriceAfterSecond, _initialSharePrice, "Share price changed after second deposit");
    }

    /// @notice Fuzz test: share price increases with yield settlement
    function testFuzz_SharePrice_IncreasesWithYield(uint256 _depositAmount, uint256 _yieldPercent) public {
        _depositAmount = bound(_depositAmount, 1000 * _1_USDC, MAX_DEPOSIT);
        _yieldPercent = bound(_yieldPercent, 1, 100); // 1-100% yield

        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        metaWallet.deposit(_depositAmount, users.alice);
        vm.stopPrank();

        uint256 _sharePriceBefore = metaWallet.sharePrice();

        uint256 _yield = (_depositAmount * _yieldPercent) / 100;
        uint256 _newTotalAssets = _depositAmount + _yield;
        bytes32 _merkleRoot = keccak256(abi.encodePacked("yield", _yield));

        vm.prank(users.executor);
        metaWallet.settleTotalAssets(_newTotalAssets, _merkleRoot);

        uint256 _sharePriceAfter = metaWallet.sharePrice();
        assertGt(_sharePriceAfter, _sharePriceBefore, "Share price should increase with yield");
    }

    /// @notice Fuzz test: share price decreases with loss settlement
    function testFuzz_SharePrice_DecreasesWithLoss(uint256 _depositAmount, uint256 _lossPercent) public {
        _depositAmount = bound(_depositAmount, 1000 * _1_USDC, MAX_DEPOSIT);
        _lossPercent = bound(_lossPercent, 1, 50); // 1-50% loss (not 100% to avoid division issues)

        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        metaWallet.deposit(_depositAmount, users.alice);
        vm.stopPrank();

        uint256 _sharePriceBefore = metaWallet.sharePrice();

        uint256 _loss = (_depositAmount * _lossPercent) / 100;
        uint256 _newTotalAssets = _depositAmount - _loss;
        bytes32 _merkleRoot = keccak256(abi.encodePacked("loss", _loss));

        vm.prank(users.executor);
        metaWallet.settleTotalAssets(_newTotalAssets, _merkleRoot);

        uint256 _sharePriceAfter = metaWallet.sharePrice();
        assertLt(_sharePriceAfter, _sharePriceBefore, "Share price should decrease with loss");
    }

    /* ///////////////////////////////////////////////////////////////
                    FUZZ TEST: MULTI-USER PROPORTIONS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: multiple users get proportional shares
    function testFuzz_MultiUser_ShareProportions(uint256 _aliceDeposit, uint256 _bobDeposit) public {
        _aliceDeposit = bound(_aliceDeposit, 100 * _1_USDC, MAX_DEPOSIT / 2);
        _bobDeposit = bound(_bobDeposit, 100 * _1_USDC, MAX_DEPOSIT / 2);

        deal(USDC_MAINNET, users.alice, _aliceDeposit);
        deal(USDC_MAINNET, users.bob, _bobDeposit);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_aliceDeposit, users.alice, users.alice);
        uint256 _aliceShares = metaWallet.deposit(_aliceDeposit, users.alice);
        vm.stopPrank();

        vm.startPrank(users.bob);
        metaWallet.requestDeposit(_bobDeposit, users.bob, users.bob);
        uint256 _bobShares = metaWallet.deposit(_bobDeposit, users.bob);
        vm.stopPrank();

        uint256 _totalDeposit = _aliceDeposit + _bobDeposit;
        uint256 _totalShares = metaWallet.totalSupply();

        // Check proportions (with 0.01% tolerance for rounding)
        uint256 _expectedAliceSharePercent = (_aliceDeposit * 10_000) / _totalDeposit;
        uint256 _actualAliceSharePercent = (_aliceShares * 10_000) / _totalShares;
        assertApproxEqAbs(_actualAliceSharePercent, _expectedAliceSharePercent, 1, "Alice share proportion mismatch");

        uint256 _expectedBobSharePercent = (_bobDeposit * 10_000) / _totalDeposit;
        uint256 _actualBobSharePercent = (_bobShares * 10_000) / _totalShares;
        assertApproxEqAbs(_actualBobSharePercent, _expectedBobSharePercent, 1, "Bob share proportion mismatch");
    }

    /// @notice Fuzz test: yield is distributed proportionally to shareholders
    function testFuzz_MultiUser_YieldDistribution(
        uint256 _aliceDeposit,
        uint256 _bobDeposit,
        uint256 _yieldPercent
    )
        public
    {
        _aliceDeposit = bound(_aliceDeposit, 1000 * _1_USDC, MAX_DEPOSIT / 3);
        _bobDeposit = bound(_bobDeposit, 1000 * _1_USDC, MAX_DEPOSIT / 3);
        _yieldPercent = bound(_yieldPercent, 1, 50); // 1-50% yield

        deal(USDC_MAINNET, users.alice, _aliceDeposit);
        deal(USDC_MAINNET, users.bob, _bobDeposit);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_aliceDeposit, users.alice, users.alice);
        uint256 _aliceShares = metaWallet.deposit(_aliceDeposit, users.alice);
        vm.stopPrank();

        vm.startPrank(users.bob);
        metaWallet.requestDeposit(_bobDeposit, users.bob, users.bob);
        uint256 _bobShares = metaWallet.deposit(_bobDeposit, users.bob);
        vm.stopPrank();

        uint256 _totalDeposit = _aliceDeposit + _bobDeposit;
        uint256 _yield = (_totalDeposit * _yieldPercent) / 100;
        uint256 _newTotalAssets = _totalDeposit + _yield;

        // Simulate yield by dealing extra USDC to vault for redemptions
        deal(USDC_MAINNET, address(metaWallet), _newTotalAssets);

        bytes32 _merkleRoot = keccak256(abi.encodePacked("yield", _yield));
        vm.prank(users.executor);
        metaWallet.settleTotalAssets(_newTotalAssets, _merkleRoot);

        // Check Alice's share of yield
        uint256 _aliceValue = metaWallet.convertToAssets(_aliceShares);
        uint256 _expectedAliceValue = _aliceDeposit + (_yield * _aliceDeposit) / _totalDeposit;
        assertApproxEqAbs(_aliceValue, _expectedAliceValue, 2, "Alice yield distribution mismatch");

        // Check Bob's share of yield
        uint256 _bobValue = metaWallet.convertToAssets(_bobShares);
        uint256 _expectedBobValue = _bobDeposit + (_yield * _bobDeposit) / _totalDeposit;
        assertApproxEqAbs(_bobValue, _expectedBobValue, 2, "Bob yield distribution mismatch");
    }

    /* ///////////////////////////////////////////////////////////////
                    FUZZ TEST: CONVERSION FUNCTIONS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: convertToShares and convertToAssets are inverse operations
    function testFuzz_ConvertFunctions_Inverse(uint256 _depositAmount, uint256 _testAssets) public {
        _depositAmount = bound(_depositAmount, 1000 * _1_USDC, MAX_DEPOSIT);
        _testAssets = bound(_testAssets, 1, _depositAmount);

        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        metaWallet.deposit(_depositAmount, users.alice);
        vm.stopPrank();

        uint256 _shares = metaWallet.convertToShares(_testAssets);
        uint256 _assetsBack = metaWallet.convertToAssets(_shares);

        // Allow 1 wei rounding error due to integer division
        assertApproxEqAbs(_assetsBack, _testAssets, 1, "Convert functions should be inverse");
    }

    /// @notice Fuzz test: convertToShares rounds down (conservative for deposits)
    function testFuzz_ConvertToShares_RoundsDown(uint256 _depositAmount, uint256 _yieldPercent) public {
        _depositAmount = bound(_depositAmount, 1000 * _1_USDC, MAX_DEPOSIT);
        _yieldPercent = bound(_yieldPercent, 1, 100);

        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        metaWallet.deposit(_depositAmount, users.alice);
        vm.stopPrank();

        // Add yield to change share price
        uint256 _yield = (_depositAmount * _yieldPercent) / 100;
        uint256 _newTotalAssets = _depositAmount + _yield;
        vm.prank(users.executor);
        metaWallet.settleTotalAssets(_newTotalAssets, keccak256("yield"));

        // Test that shares * price >= assets (i.e., shares rounds down)
        uint256 _testAssets = 12_345 * _1_USDC;
        uint256 _shares = metaWallet.convertToShares(_testAssets);
        uint256 _assetsFromShares = metaWallet.convertToAssets(_shares);

        assertLe(_assetsFromShares, _testAssets, "convertToShares should round down");
    }

    /* ///////////////////////////////////////////////////////////////
                    FUZZ TEST: TOTAL IDLE CALCULATIONS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: totalIdle correctly excludes pending deposits
    function testFuzz_TotalIdle_ExcludesPendingDeposits(uint256 _deposit1, uint256 _deposit2) public {
        _deposit1 = bound(_deposit1, MIN_DEPOSIT, MAX_DEPOSIT / 2);
        _deposit2 = bound(_deposit2, MIN_DEPOSIT, MAX_DEPOSIT / 2);

        // First user deposits and claims
        deal(USDC_MAINNET, users.alice, _deposit1);
        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_deposit1, users.alice, users.alice);
        metaWallet.deposit(_deposit1, users.alice);
        vm.stopPrank();

        uint256 _totalIdleAfterFirst = metaWallet.totalIdle();
        assertEq(_totalIdleAfterFirst, _deposit1, "TotalIdle should equal first deposit");

        // Second user requests but doesn't claim
        deal(USDC_MAINNET, users.bob, _deposit2);
        vm.prank(users.bob);
        metaWallet.requestDeposit(_deposit2, users.bob, users.bob);

        uint256 _totalIdleAfterSecondRequest = metaWallet.totalIdle();
        assertEq(_totalIdleAfterSecondRequest, _deposit1, "TotalIdle should exclude pending deposits");

        // Second user claims
        vm.prank(users.bob);
        metaWallet.deposit(_deposit2, users.bob);

        uint256 _totalIdleAfterSecondClaim = metaWallet.totalIdle();
        assertEq(_totalIdleAfterSecondClaim, _deposit1 + _deposit2, "TotalIdle should include both deposits");
    }

    /* ///////////////////////////////////////////////////////////////
                    FUZZ TEST: SETTLEMENT
    ///////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: settlement correctly updates totalAssets
    function testFuzz_Settlement_UpdatesTotalAssets(uint256 _depositAmount, uint256 _newTotalAssets) public {
        _depositAmount = bound(_depositAmount, 1000 * _1_USDC, MAX_DEPOSIT);
        _newTotalAssets = bound(_newTotalAssets, 1, MAX_DEPOSIT * 2);

        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        metaWallet.deposit(_depositAmount, users.alice);
        vm.stopPrank();

        bytes32 _merkleRoot = keccak256(abi.encodePacked("settlement", _newTotalAssets));

        vm.prank(users.executor);
        metaWallet.settleTotalAssets(_newTotalAssets, _merkleRoot);

        assertEq(metaWallet.totalAssets(), _newTotalAssets, "TotalAssets not updated correctly");
        assertEq(metaWallet.merkleRoot(), _merkleRoot, "MerkleRoot not updated correctly");
    }

    /* ///////////////////////////////////////////////////////////////
                    FUZZ TEST: MAX DEPOSIT/REDEEM LIMITS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: maxRedeem is limited by totalIdle
    function testFuzz_MaxRedeem_LimitedByTotalIdle(uint256 _depositAmount, uint256 _externalAmount) public {
        _depositAmount = bound(_depositAmount, 1000 * _1_USDC, MAX_DEPOSIT);
        _externalAmount = bound(_externalAmount, 1, _depositAmount - 1);

        deal(USDC_MAINNET, users.alice, _depositAmount);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_depositAmount, users.alice, users.alice);
        uint256 _shares = metaWallet.deposit(_depositAmount, users.alice);
        metaWallet.requestRedeem(_shares, users.alice, users.alice);
        vm.stopPrank();

        // Simulate external investment by reducing vault balance
        uint256 _idleAmount = _depositAmount - _externalAmount;
        deal(USDC_MAINNET, address(metaWallet), _idleAmount);

        uint256 _maxRedeem = metaWallet.maxRedeem(users.alice);
        uint256 _idleShares = metaWallet.convertToShares(_idleAmount);

        assertLe(_maxRedeem, _idleShares, "MaxRedeem should be limited by idle shares");
    }

    /* ///////////////////////////////////////////////////////////////
                    FUZZ TEST: INVARIANTS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Fuzz invariant: totalSupply * sharePrice ~= totalAssets (within rounding)
    function testFuzz_Invariant_TotalSupplyTimesSharePrice(
        uint256 _deposit1,
        uint256 _deposit2,
        uint256 _yieldPercent
    )
        public
    {
        _deposit1 = bound(_deposit1, 1000 * _1_USDC, MAX_DEPOSIT / 3);
        _deposit2 = bound(_deposit2, 1000 * _1_USDC, MAX_DEPOSIT / 3);
        _yieldPercent = bound(_yieldPercent, 0, 100);

        deal(USDC_MAINNET, users.alice, _deposit1);
        deal(USDC_MAINNET, users.bob, _deposit2);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_deposit1, users.alice, users.alice);
        metaWallet.deposit(_deposit1, users.alice);
        vm.stopPrank();

        vm.startPrank(users.bob);
        metaWallet.requestDeposit(_deposit2, users.bob, users.bob);
        metaWallet.deposit(_deposit2, users.bob);
        vm.stopPrank();

        // Apply yield/loss
        uint256 _totalDeposit = _deposit1 + _deposit2;
        uint256 _newTotalAssets = _totalDeposit + (_totalDeposit * _yieldPercent) / 100;

        if (_yieldPercent > 0) {
            vm.prank(users.executor);
            metaWallet.settleTotalAssets(_newTotalAssets, keccak256("yield"));
        }

        // Check invariant: totalSupply * sharePrice / 10^decimals ~= totalAssets
        uint256 _totalSupply = metaWallet.totalSupply();
        uint256 _sharePrice = metaWallet.sharePrice();
        uint256 _decimals = VaultModule(address(metaWallet)).decimals();
        uint256 _calculatedTotalAssets = (_totalSupply * _sharePrice) / (10 ** _decimals);
        uint256 _actualTotalAssets = metaWallet.totalAssets();

        // Allow small rounding error (0.01%)
        assertApproxEqRel(
            _calculatedTotalAssets, _actualTotalAssets, 0.0001e18, "Invariant: totalSupply * sharePrice != totalAssets"
        );
    }

    /// @notice Fuzz invariant: sum of all user shares equals totalSupply
    function testFuzz_Invariant_SumOfSharesEqualsTotalSupply(uint256 _deposit1, uint256 _deposit2) public {
        _deposit1 = bound(_deposit1, MIN_DEPOSIT, MAX_DEPOSIT / 2);
        _deposit2 = bound(_deposit2, MIN_DEPOSIT, MAX_DEPOSIT / 2);

        deal(USDC_MAINNET, users.alice, _deposit1);
        deal(USDC_MAINNET, users.bob, _deposit2);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_deposit1, users.alice, users.alice);
        uint256 _aliceShares = metaWallet.deposit(_deposit1, users.alice);
        vm.stopPrank();

        vm.startPrank(users.bob);
        metaWallet.requestDeposit(_deposit2, users.bob, users.bob);
        uint256 _bobShares = metaWallet.deposit(_deposit2, users.bob);
        vm.stopPrank();

        uint256 _totalSupply = metaWallet.totalSupply();
        assertEq(_aliceShares + _bobShares, _totalSupply, "Sum of shares should equal totalSupply");
    }

    /* ///////////////////////////////////////////////////////////////
                    FUZZ TEST: EDGE CASES
    ///////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: very small deposits don't cause issues
    function testFuzz_SmallDeposits(uint256 _smallDeposit) public {
        _smallDeposit = bound(_smallDeposit, 1, 1000); // 1 wei to 1000 wei

        deal(USDC_MAINNET, users.alice, _smallDeposit);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_smallDeposit, users.alice, users.alice);
        uint256 _shares = metaWallet.deposit(_smallDeposit, users.alice);
        vm.stopPrank();

        // Should get at least 1 share for any deposit
        assertGe(_shares, _smallDeposit > 0 ? 1 : 0, "Should get shares for non-zero deposit");
        assertEq(metaWallet.totalAssets(), _smallDeposit, "TotalAssets should match deposit");
    }

    /// @notice Fuzz test: large deposits don't overflow
    function testFuzz_LargeDeposits(uint256 _largeDeposit) public {
        _largeDeposit = bound(_largeDeposit, MAX_DEPOSIT / 2, MAX_DEPOSIT);

        deal(USDC_MAINNET, users.alice, _largeDeposit);

        vm.startPrank(users.alice);
        metaWallet.requestDeposit(_largeDeposit, users.alice, users.alice);
        uint256 _shares = metaWallet.deposit(_largeDeposit, users.alice);
        vm.stopPrank();

        assertEq(_shares, _largeDeposit, "Large deposit should work correctly");
        assertEq(metaWallet.totalAssets(), _largeDeposit, "TotalAssets should match large deposit");
    }

    /// @notice Fuzz test: multiple sequential operations maintain consistency
    function testFuzz_SequentialOperations(uint256 _seed) public {
        _seed = bound(_seed, 1, type(uint128).max);

        uint256 _totalDeposited = 0;
        uint256 _totalRedeemed = 0;

        // Perform 5 random operations
        for (uint256 i = 0; i < 5; i++) {
            uint256 _amount = (uint256(keccak256(abi.encodePacked(_seed, i))) % (10_000 * _1_USDC)) + _1_USDC;

            if (i % 2 == 0) {
                // Deposit
                deal(USDC_MAINNET, users.alice, USDC_MAINNET.balanceOf(users.alice) + _amount);
                vm.startPrank(users.alice);
                metaWallet.requestDeposit(_amount, users.alice, users.alice);
                metaWallet.deposit(_amount, users.alice);
                vm.stopPrank();
                _totalDeposited += _amount;
            } else {
                // Redeem (if we have shares)
                uint256 _shares = metaWallet.balanceOf(users.alice);
                if (_shares > 0) {
                    uint256 _redeemShares = _shares / 2;
                    if (_redeemShares > 0) {
                        vm.startPrank(users.alice);
                        metaWallet.requestRedeem(_redeemShares, users.alice, users.alice);
                        uint256 _assetsOut = metaWallet.redeem(_redeemShares, users.alice, users.alice);
                        vm.stopPrank();
                        _totalRedeemed += _assetsOut;
                    }
                }
            }

            // After each operation, verify basic invariants
            assertEq(
                metaWallet.totalAssets(),
                _totalDeposited - _totalRedeemed,
                "TotalAssets should equal deposits minus redemptions"
            );
        }
    }
}
