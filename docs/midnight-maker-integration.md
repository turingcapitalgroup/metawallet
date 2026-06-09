# MetaWallet x Morpho Midnight Maker Integration

## 1. Purpose

This document specifies what MetaWallet needs in order to act as a contract-based
maker lender on Morpho Midnight.

The goal is for MetaWallet to post fixed-rate Midnight offers while keeping its
capital invested in other strategies. When an offer fills, Midnight should call
back into MetaWallet, MetaWallet should source the required loan tokens from its
idle balance and configured liquidation queue, and the fill should complete
atomically.

The same integration must also let MetaWallet exit Midnight credit positions:

- withdraw loan tokens after borrower repayment or liquidation creates
  Midnight withdrawable liquidity;
- sell Midnight credit before maturity so MetaWallet is not forced to wait for
  repayment.

The design follows the existing MetaWallet architecture:

- `MetaWallet` remains the account, vault, and proxy address.
- Midnight support is added as a facet module through `MultiFacetProxy`.
- External protocol interactions remain registry-gated.
- Strategy-specific unwinds are configured as reusable policy, not embedded in
  every offer.
- The Midnight callback path uses direct registry-authorized calls or strategy
  adapters, not `executeWithHookExecution`, because the callback should be
  `nonReentrant` and the existing hook executor is also `nonReentrant`.

## 2. Context

### 2.1 Midnight Maker Lending

For a lender-maker offer, MetaWallet publishes an offchain Midnight offer with:

```solidity
offer.buy = true;
offer.maker = address(metaWallet);
offer.callback = address(metaWallet);
offer.ratifier = address(setterRatifier);
```

When a taker fills that offer through `Midnight.take`, Midnight treats
MetaWallet as the buyer of credit units. If `offer.callback` is non-zero,
Midnight calls `onBuy` before pulling the loan tokens from the callback address.

For a contract maker this callback is the critical integration point. It gives
MetaWallet one transaction to liquidate enough capital, approve Midnight, and
return the expected callback success value.

### 2.2 MetaWallet Execution Model

MetaWallet already has three properties that make it a good Midnight maker:

- It is a smart account with arbitrary execution, subject to registry policy.
- It can be extended through selector-based modules.
- It has hooks for reusable strategy actions such as ERC-4626 deposit, ERC-4626
  redeem, and swaps.

However, Midnight callbacks are initiated by the Midnight contract, not by an
executor account. The callback entry points therefore need to live on the
MetaWallet address itself, which makes a facet module the right integration
surface.

Existing hooks are still useful for normal pre-fill and post-fill portfolio
management. During the synchronous Midnight callback, the liquidation queue
should use direct calls or small adapters so it does not reenter
`executeWithHookExecution`.

## 3. Required Component: `MidnightModule`

`MidnightModule` should be a MetaWallet facet installed through
`MultiFacetProxy`. It should implement Midnight callback interfaces and expose
management functions for offer ratification, authorization, liquidity sourcing,
credit withdrawal, and credit sale.

The module should be called through the MetaWallet proxy address and should
store its state in an ERC-7201 namespaced storage slot.

Important liquidity policy: MetaWallet must not automatically treat its full
idle loan-token balance as available for Midnight fills. The admin configures an
idle usage cap per loan token. The callback may consume at most that capped idle
amount and must source the rest from the liquidation queue.

### 3.1 Files To Add

Use these files so the feature follows the current repo layout:

- `src/interfaces/IMidnight.sol`: minimal Midnight structs and entry points
  required by MetaWallet. Copy only `Market`, `CollateralParams`, `Offer`,
  `take`, `withdraw`, `setConsumed`, `setIsAuthorized`, `toId`, and any view
  helpers used by tests.
- `src/interfaces/IMidnightCallbacks.sol`: `IBuyCallback` and `ISellCallback`
  with the same signatures as Morpho Midnight.
- `src/interfaces/ISetterRatifier.sol`: `setIsRootRatified(address,bytes32,bool)`.
- `src/interfaces/IMidnightModule.sol`: the MetaWallet-facing interface below.
- `src/interfaces/IStrategyLiquidationAdapter.sol`: optional standard adapter
  interface for strategies that cannot withdraw the loan token by desired asset
  amount directly.
- `src/modules/MidnightModule.sol`: the facet implementation.
- `test/MidnightModule.t.sol`: production-like tests using the existing
  MetaWallet deployment flow.

Do not add a README dependency for this spec. The spec document is the source
of truth for building the module.

### 3.2 Interfaces

The module should implement:

```solidity
interface IMidnightModule {
    event MidnightConfigUpdated(address indexed midnight, address indexed setterRatifier);
    event MidnightAuthorizationUpdated(address indexed authorized, bool enabled);
    event OfferTreeRatified(bytes32 indexed root, bool enabled);
    event OfferGroupCancelled(bytes32 indexed group);
    event IdleLiquidityCapUpdated(address indexed loanToken, uint256 oldCap, uint256 newCap);
    event LiquidationQueueUpdated(address indexed loanToken, uint256 stepCount);
    event LiquidationQueueCleared(address indexed loanToken);
    event LiquidationStepExecuted(
        address indexed loanToken,
        uint256 indexed index,
        address indexed target,
        uint256 requestedAmount,
        uint256 outputAmount
    );
    event MidnightCreditWithdrawn(bytes32 indexed marketId, uint256 units, address indexed receiver);
    event MidnightOfferTaken(bytes32 indexed marketId, uint256 units, uint256 buyerAssets, uint256 sellerAssets);
    event MidnightBuyCallbackFunded(bytes32 indexed marketId, uint256 buyerAssets, uint256 finalBalance);
    event MidnightSellCallbackValidated(bytes32 indexed marketId, uint256 sellerAssets, address indexed receiver);

    struct MidnightConfig {
        address midnight;
        address setterRatifier;
    }

    struct LiquidationStep {
        address target;
        uint256 value;
        bytes callDataTemplate;
        uint256 amountPlaceholderOffset;
        uint256 maxLiquidationAmount;
        address expectedOutputToken;
        uint256 minOutputAmount;
        bool enabled;
    }

    struct BuyCallbackData {
        bytes32 expectedMarketId;
        uint256 minFinalLoanTokenBalance;
    }

    struct SellCallbackData {
        bytes32 expectedMarketId;
        address expectedReceiver;
        uint256 minFinalLoanTokenBalance;
    }

    function setMidnightConfig(address midnight, address setterRatifier) external;
    function setMidnightAuthorization(address authorized, bool enabled) external;
    function ratifyOfferTree(bytes32 root, bool enabled) external;
    function cancelOfferGroup(bytes32 group) external;

    function setIdleLiquidityCap(address loanToken, uint256 cap) external;
    function idleLiquidityCap(address loanToken) external view returns (uint256);
    function setLiquidationQueue(address loanToken, LiquidationStep[] calldata steps) external;
    function clearLiquidationQueue(address loanToken) external;
    function liquidationQueue(address loanToken, uint256 index) external view returns (LiquidationStep memory);
    function liquidationQueueLength(address loanToken) external view returns (uint256);

    function withdrawCredits(Market calldata market, uint256 units, address receiver) external;
    function takeOffer(
        Offer calldata offer,
        bytes calldata ratifierData,
        uint256 units,
        address receiverIfTakerIsSeller,
        address takerCallback,
        bytes calldata takerCallbackData
    ) external returns (uint256 buyerAssets, uint256 sellerAssets);

    function onBuy(
        bytes32 id,
        Market calldata market,
        uint256 buyerAssets,
        uint256 units,
        uint256 pendingFeeIncrease,
        address buyer,
        bytes calldata data
    ) external returns (bytes32);

    function onSell(
        bytes32 id,
        Market calldata market,
        uint256 sellerAssets,
        uint256 units,
        uint256 pendingFeeDecrease,
        address seller,
        address receiver,
        bytes calldata data
    ) external returns (bytes32);
}
```

The concrete implementation can use `memory` instead of `calldata` where needed
to match Midnight's existing callback interfaces.

Recommended adapter interface:

```solidity
interface IStrategyLiquidationAdapter {
    function liquidate(uint256 assets, address receiver) external returns (uint256 assetsOut);
}
```

Adapters should be stateless or ownerless where possible. They should assume
`msg.sender` is MetaWallet, pull or use strategy positions owned by MetaWallet,
and deliver `assetsOut` of the Midnight loan token to `receiver`.

### 3.3 Storage

`MidnightModule` should use a dedicated ERC-7201 namespace:

```solidity
/// @custom:storage-location erc7201:metawallet.storage.MidnightModule
struct MidnightModuleStorage {
    address midnight;
    address setterRatifier;
    mapping(address loanToken => uint256 cap) idleLiquidityCaps;
    mapping(address loanToken => LiquidationStep[] steps) liquidationQueues;
}
```

Use the same storage pattern as `VaultModule`: define a constant storage slot
and an internal `_getMidnightModuleStorage()` function. Do not reuse
`VaultModule` or `HookExecution` storage.

### 3.4 Constants And Return Values

Define the Midnight callback success value locally so the module can validate
and return the exact value expected by Midnight:

```solidity
bytes32 internal constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");
```

### 3.5 Errors

Add typed errors or repo-style string constants for at least:

- `MIDNIGHT_INVALID_ADDRESS`
- `MIDNIGHT_NOT_CONFIGURED`
- `MIDNIGHT_ONLY_MIDNIGHT`
- `MIDNIGHT_UNAUTHORIZED`
- `MIDNIGHT_INVALID_BUYER`
- `MIDNIGHT_INVALID_SELLER`
- `MIDNIGHT_INVALID_RECEIVER`
- `MIDNIGHT_INVALID_MARKET`
- `MIDNIGHT_INVALID_LOAN_TOKEN`
- `MIDNIGHT_INVALID_LIQUIDATION_STEP`
- `MIDNIGHT_INVALID_PLACEHOLDER_OFFSET`
- `MIDNIGHT_LIQUIDATION_CALL_FAILED`
- `MIDNIGHT_INSUFFICIENT_LIQUIDITY`
- `MIDNIGHT_INSUFFICIENT_STEP_OUTPUT`

Keep the error style consistent with the rest of the repository.

### 3.6 Selectors

The module's `selectors()` function must include all public and callback entry
points, including:

- `setMidnightConfig`
- `setMidnightAuthorization`
- `ratifyOfferTree`
- `cancelOfferGroup`
- `setIdleLiquidityCap`
- `idleLiquidityCap`
- `setLiquidationQueue`
- `clearLiquidationQueue`
- `liquidationQueue`
- `liquidationQueueLength`
- `withdrawCredits`
- `takeOffer`
- `onBuy`
- `onSell`

The selector array size must exactly match the number of selectors returned, as
`VaultModule.selectors()` does today.

## 4. Configuration And Ratification

### 4.0 Role Checks

`MidnightModule` is executed by delegatecall from the MetaWallet proxy, so role
checks should read the same `OwnableRoles` storage used by `MetaWallet` and
`VaultModule`.

Required role policy:

- Admin-only: config, Midnight authorization, root ratification, group
  cancellation, idle liquidity cap updates, queue replacement, queue clearing.
- Executor-or-admin: `withdrawCredits` and `takeOffer`.
- Midnight-only: `onBuy` and `onSell`.

The implementation can inherit `OwnableRoles` like `VaultModule` and define:

```solidity
uint256 public constant ADMIN_ROLE = _ROLE_0;
uint256 public constant EXECUTOR_ROLE = _ROLE_1;
```

For executor-or-admin functions, accept callers with either role or the owner.

### 4.1 Midnight Config

`setMidnightConfig(address midnight, address setterRatifier)` should be
restricted to MetaWallet admin authority and should reject zero addresses.

The module stores:

- the canonical Midnight contract address;
- the `SetterRatifier` address used by MetaWallet to ratify offer trees.

Emit `MidnightConfigUpdated(midnight, setterRatifier)`.

### 4.2 Authorizing The Ratifier

Before `SetterRatifier` can ratify MetaWallet offers, MetaWallet must authorize
it in Midnight:

```solidity
Midnight.setIsAuthorized(setterRatifier, true, address(this));
```

The module should expose:

```solidity
setMidnightAuthorization(address authorized, bool enabled)
```

This should call Midnight with `onBehalf = address(this)`. It allows MetaWallet
to authorize or revoke the configured ratifier, an offchain offer manager, or a
future custom ratifier.

Midnight authorizations are broad, so this function should be admin-gated and
documented as a high-trust operation.

Emit `MidnightAuthorizationUpdated(authorized, enabled)`.

### 4.3 Ratifying Offer Trees

The default contract-maker flow uses `SetterRatifier`:

```solidity
SetterRatifier.setIsRootRatified(address(this), root, enabled);
```

The module should expose:

```solidity
ratifyOfferTree(bytes32 root, bool enabled)
```

This lets the admin publish or cancel Merkle roots containing MetaWallet offers.
The offers themselves stay offchain and can be distributed through any Midnight
router, solver, RFQ system, or private counterparty.

Emit `OfferTreeRatified(root, enabled)`.

### 4.4 Cancelling Consumption Groups

The module should expose:

```solidity
cancelOfferGroup(bytes32 group)
```

This should call:

```solidity
Midnight.setConsumed(group, type(uint256).max, address(this));
```

Setting a group to `type(uint256).max` cancels remaining fills in that group.
This is the fastest way to shut down a family of offers without changing every
offchain quote.

Emit `OfferGroupCancelled(group)`.

## 5. Liquidity Sourcing Queue

### 5.1 Design Goal

MetaWallet should not have to keep all Midnight lending liquidity idle. Instead,
the admin configures a liquidation queue per loan token. When Midnight calls
`onBuy`, the module first checks how much of the current MetaWallet loan-token
balance is allowed to be consumed by the configured idle cap. If the capped idle
amount is not enough, it walks the queue and executes liquidation steps until
the fill is funded.

Idle balance is always source zero, but only up to `idleLiquidityCap[loanToken]`.
The cap defaults to `0`, meaning a newly configured loan token will not consume
idle balance during Midnight fills until the admin opts in. To allow unlimited
idle usage for a token, set the cap to `type(uint256).max`.

The queue is intentionally lower-level than the normal hook system. A step is a
single registry-authorized external call with optional amount injection. Complex
unwinds that require multiple operations should be represented as multiple queue
steps or as one strategy adapter call.

### 5.2 Queue Semantics

Each loan token has an ordered array of `LiquidationStep`.

Execution rules:

1. Compute required balance: `buyerAssets`.
2. Read starting balance of `market.loanToken` on `address(this)`.
3. Compute capped idle usage:
   `usableIdle = min(startBalance, idleLiquidityCap[loanToken], buyerAssets)`.
4. Compute protected idle:
   `protectedIdle = startBalance - usableIdle`.
5. Compute queue deficit: `deficit = buyerAssets - usableIdle`.
6. If `deficit == 0`, skip the queue.
7. Otherwise walk the queue.
8. For each enabled step in order:
   - cap the requested output amount to `min(deficit, maxLiquidationAmount)`;
   - inject that amount into `callDataTemplate` at `amountPlaceholderOffset`;
   - snapshot `expectedOutputToken.balanceOf(address(this))`;
   - execute `target.call{value: value}(patchedCalldata)`;
   - compute output delta;
   - require output delta is at least `minOutputAmount`, unless
     `minOutputAmount == 0`;
   - update current loan-token balance;
   - recompute `deficit = zeroFloorSub(buyerAssets + protectedIdle, currentBalance)`;
   - stop as soon as `currentBalance >= buyerAssets + protectedIdle`.
9. If the full queue finishes and `currentBalance < buyerAssets + protectedIdle`,
   revert.

This is an "until funded" queue. It avoids unnecessary liquidations when idle
balance within the configured cap or earlier sources already cover the fill.

The protected-idle check matters because Midnight pulls fungible tokens after
`onBuy` returns. The module cannot choose which specific tokens Midnight pulls,
so it must ensure that before the pull the balance is at least
`buyerAssets + protectedIdle`. After Midnight pulls `buyerAssets`, the remaining
balance is at least the protected idle amount.

### 5.3 Idle Liquidity Cap Management

The module should expose:

```solidity
setIdleLiquidityCap(address loanToken, uint256 cap)
idleLiquidityCap(address loanToken) external view returns (uint256)
```

`setIdleLiquidityCap` should be admin-gated, reject `loanToken == address(0)`,
store the new cap, and emit:

```solidity
event IdleLiquidityCapUpdated(address indexed loanToken, uint256 oldCap, uint256 newCap);
```

The cap is denominated in raw loan-token units. If the admin wants MetaWallet to
use at most 100 USDC of idle balance for Midnight fills, the cap for USDC should
be `100e6`.

### 5.4 Calldata Template Amount Injection

`callDataTemplate` is a complete calldata blob with one 32-byte word reserved
for the dynamic amount.

`amountPlaceholderOffset` is the byte offset in the calldata where the 32-byte
amount word starts. The module should replace that word with:

```solidity
min(currentDeficit, step.maxLiquidationAmount)
```

For v1, the injected amount must be denominated in `expectedOutputToken`, which
must be the Midnight loan token. Therefore each queue step must target a
function whose amount argument requests an output amount in the same token. Good
examples:

```solidity
IERC4626(vault).withdraw(assets, address(metaWallet), address(metaWallet));
IStrategyLiquidationAdapter(adapter).liquidate(assets, address(metaWallet));
```

Do not use a raw ERC-4626 `redeem(shares, receiver, owner)` template for v1
unless it is wrapped by an adapter that accepts a desired asset amount. A redeem
call's first argument is shares, not loan-token assets, so injecting the
loan-token deficit into that field would be unit-incorrect.

Validation requirements:

- `callDataTemplate.length >= 4`;
- `amountPlaceholderOffset >= 4`;
- `amountPlaceholderOffset + 32 <= callDataTemplate.length`;
- `maxLiquidationAmount > 0`;
- `target != address(0)`;
- `expectedOutputToken == loanToken`.

The placeholder model supports protocols with normal ABI-encoded amount
arguments, including ERC-4626 `withdraw(assets, receiver, owner)` where the
first argument is the desired asset amount.

Implementation rule:

```solidity
function _patchAmount(
    bytes memory callData,
    uint256 offset,
    uint256 amount
) internal pure returns (bytes memory patched) {
    patched = callData;
    assembly {
        mstore(add(add(patched, 0x20), offset), amount)
    }
}
```

The implementation must validate the offset before calling the assembly helper.
The offset is counted from the first byte of calldata, so for a normal ABI call
where the first argument is the dynamic amount, `amountPlaceholderOffset == 4`.

### 5.5 Registry Enforcement

Every liquidation call must pass through the same registry authorization used by
MetaWallet hook execution. The implementation should reuse the wallet's
registry authorization path or provide an equivalent internal helper that:

- extracts the selector from patched calldata;
- extracts calldata parameters after the selector;
- calls `registry.authorizeCall(target, selector, params)`;
- only then executes the call.

This preserves MetaWallet's defense-in-depth model. An admin-configured queue is
not enough by itself; the registry must still permit the target, selector, and
parameters.

Do not implement callback liquidation by calling
`MetaWallet.executeWithHookExecution` from inside `onBuy`. `MetaWallet` already
uses `ReentrancyGuard` on hook execution, and `onBuy` should also be guarded.
Calling the hook executor from the callback would therefore either revert or
force the callback to drop reentrancy protection. Use direct strategy calls or
adapter contracts instead.

Build this explicitly in `MidnightModule`; do not bypass the registry with a raw
`target.call`.

The module cannot call `MetaWallet._executeOperations` because that function is
internal. It should instead query the registry through the public smart-account
interface and run the same selector/params authorization check:

```solidity
function _executeRegistryAuthorizedCall(
    address target,
    uint256 value,
    bytes memory callData
) internal returns (bytes memory result) {
    bytes4 selector = bytes4(callData);
    bytes memory params = callData.length > 4 ? _sliceParams(callData) : bytes("");
    IMinimalSmartAccount(address(this)).registry().authorizeCall(target, selector, params);

    (bool success, bytes memory returnData) = target.call{value: value}(callData);
    if (!success) _bubbleRevert(returnData);
    return returnData;
}
```

The exact helper implementation can use inline assembly for `_sliceParams`, as
`MetaWallet._executeOperations` already does. It does not need to increment the
smart-account nonce unless the team explicitly wants queue executions reflected
in the global execution nonce.

### 5.6 Queue Management

`setLiquidationQueue(address loanToken, LiquidationStep[] calldata steps)`
should replace the full queue for that token.

`clearLiquidationQueue(address loanToken)` should delete the queue.

Replacing the full queue is preferred over per-index mutation because it avoids
partial updates and makes offchain review easier.

The module should emit:

```solidity
event LiquidationQueueUpdated(address indexed loanToken, uint256 stepCount);
event LiquidationQueueCleared(address indexed loanToken);
event LiquidationStepExecuted(
    address indexed loanToken,
    uint256 indexed index,
    address indexed target,
    uint256 requestedAmount,
    uint256 outputAmount
);
```

Queue storage should preserve full calldata templates. Because `bytes` inside a
storage array can be expensive to mutate, replace the full array by deleting the
old queue and pushing each new step after validation.

## 6. Maker Lending Flow

### 6.1 Setup

1. Admin installs `MidnightModule` selectors on MetaWallet.
2. Admin configures Midnight and SetterRatifier.
3. Admin authorizes SetterRatifier through `setMidnightAuthorization`.
4. Admin configures `idleLiquidityCap` for each Midnight loan token.
5. Admin configures a liquidation queue for each Midnight loan token.
6. Admin ratifies an offer-tree root containing lender-maker offers.
7. Offchain infrastructure publishes offers to takers or solvers.

### 6.2 Offer Shape

A lender-maker offer should use:

```solidity
Offer({
    market: market,
    buy: true,
    maker: address(metaWallet),
    start: start,
    expiry: expiry,
    tick: tick,
    group: group,
    callback: address(metaWallet),
    callbackData: abi.encode(BuyCallbackData({
        expectedMarketId: id,
        minFinalLoanTokenBalance: 0
    })),
    receiverIfMakerIsSeller: address(0),
    ratifier: address(setterRatifier),
    reduceOnly: false,
    maxUnits: maxUnits,
    maxAssets: maxBuyerAssets
});
```

`expectedMarketId` should be computed with `Midnight.toId(market)`.

`minFinalLoanTokenBalance` should normally be `0`. Midnight passes the actual
fill requirement as the live `buyerAssets` callback argument, and `onBuy` must
always fund at least that amount. Since `offer.callbackData` is included in the
offer hash, it cannot be adjusted per partial fill. Use a non-zero
`minFinalLoanTokenBalance` only when the offer is intentionally fixed-size or
when MetaWallet wants the callback to preserve an additional idle buffer.

### 6.3 `onBuy` Callback Flow

When a taker fills the offer, Midnight calls:

```solidity
onBuy(id, market, buyerAssets, units, pendingFeeIncrease, buyer, data)
```

The module should:

1. Require `msg.sender == configuredMidnight`.
2. Require `buyer == address(this)`.
3. Decode `BuyCallbackData`.
4. Require `id == expectedMarketId`.
5. Require `market.loanToken != address(0)`.
6. Compute the protected idle amount from the configured idle cap.
7. Source liquidity from capped idle balance and the liquidation queue until
   funded.
8. Require final loan-token balance is at least:
   - `buyerAssets`; and
   - `buyerAssets + protectedIdle`; and
   - `minFinalLoanTokenBalance`, if non-zero.
9. Approve Midnight for exactly `buyerAssets`.
10. Return Midnight's `CALLBACK_SUCCESS`.

After the callback returns, Midnight pulls loan tokens from the callback address.
Because `offer.callback = address(metaWallet)`, MetaWallet is the payer.

Reference implementation shape:

```solidity
function onBuy(
    bytes32 id,
    Market memory market,
    uint256 buyerAssets,
    uint256,
    uint256,
    address buyer,
    bytes memory data
) external nonReentrant returns (bytes32) {
    MidnightModuleStorage storage $ = _getMidnightModuleStorage();
    require(msg.sender == $.midnight, MIDNIGHT_ONLY_MIDNIGHT);
    require(buyer == address(this), MIDNIGHT_INVALID_BUYER);
    require(market.loanToken != address(0), MIDNIGHT_INVALID_LOAN_TOKEN);

    BuyCallbackData memory callbackData = abi.decode(data, (BuyCallbackData));
    require(id == callbackData.expectedMarketId, MIDNIGHT_INVALID_MARKET);

    uint256 protectedIdle = _fundLoanToken(market.loanToken, buyerAssets);

    uint256 finalBalance = IERC20(market.loanToken).balanceOf(address(this));
    require(finalBalance >= buyerAssets, MIDNIGHT_INSUFFICIENT_LIQUIDITY);
    require(finalBalance >= buyerAssets + protectedIdle, MIDNIGHT_INSUFFICIENT_LIQUIDITY);
    if (callbackData.minFinalLoanTokenBalance != 0) {
        require(finalBalance >= callbackData.minFinalLoanTokenBalance, MIDNIGHT_INSUFFICIENT_LIQUIDITY);
    }

    market.loanToken.safeApproveWithRetry($.midnight, buyerAssets);
    emit MidnightBuyCallbackFunded(id, buyerAssets, finalBalance);
    return CALLBACK_SUCCESS;
}
```

`_fundLoanToken` is the queue walker described in section 5. It should return
the protected idle amount that must remain after Midnight pulls `buyerAssets`.
It must use `IERC20(loanToken).balanceOf(address(this))`, not
`VaultModule.totalIdle()`, because Midnight loan tokens may differ from the
MetaWallet vault asset in future deployments.

Reference funding helper shape:

```solidity
function _fundLoanToken(address loanToken, uint256 buyerAssets) internal returns (uint256 protectedIdle) {
    MidnightModuleStorage storage $ = _getMidnightModuleStorage();
    uint256 startBalance = IERC20(loanToken).balanceOf(address(this));
    uint256 usableIdle = _min(_min(startBalance, $.idleLiquidityCaps[loanToken]), buyerAssets);
    protectedIdle = startBalance - usableIdle;
    uint256 requiredBalance = buyerAssets + protectedIdle;

    if (startBalance >= requiredBalance) return protectedIdle;

    _executeLiquidationQueueUntilFunded(loanToken, requiredBalance);
    return protectedIdle;
}
```

### 6.4 Allowance Policy

The module should not maintain a standing allowance to Midnight.

During `onBuy`, it should use an approve-use pattern:

```solidity
loanToken.safeApproveWithRetry(midnight, buyerAssets);
```

Midnight pulls the tokens immediately after the callback. If the token requires
resetting allowance to zero before reapproval, the implementation should use the
same retry-safe approval pattern already used in existing MetaWallet hooks.

The module should not reset the allowance after returning from `onBuy`, because
Midnight pulls the tokens after the callback returns. Resetting immediately
would break the fill.

## 7. Credit Exit Flow

### 7.1 Withdraw After Repayment

Midnight lender credit can only be withdrawn when the market has withdrawable
loan-token liquidity from repayments or liquidations.

The module should expose:

```solidity
withdrawCredits(Market calldata market, uint256 units, address receiver)
```

This should call:

```solidity
Midnight.withdraw(market, units, address(this), receiver);
```

This function does not unwind a live loan early. It burns MetaWallet credit and
withdraws available loan tokens.

Implementation requirements:

- require Midnight is configured;
- require `receiver != address(0)`;
- call `Midnight.toId(market)` before or after withdrawal for event indexing;
- emit `MidnightCreditWithdrawn(id, units, receiver)`.

### 7.2 Sell Credit Before Repayment

MetaWallet can exit credit before repayment by selling it in Midnight.

As maker, MetaWallet can publish:

```solidity
offer.buy = false;
offer.maker = address(metaWallet);
offer.callback = address(metaWallet);
offer.receiverIfMakerIsSeller = address(metaWallet);
offer.reduceOnly = true;
```

`reduceOnly = true` is important. It prevents the maker-side sell offer from
increasing MetaWallet debt if the position does not have enough credit to sell.

As taker, MetaWallet can sell credit into another maker's buy offer by calling:

```solidity
takeOffer(...)
```

The module should forward to:

```solidity
Midnight.take(
    offer,
    ratifierData,
    units,
    address(this),
    receiverIfTakerIsSeller,
    takerCallback,
    takerCallbackData
);
```

For early credit sales, the receiver should usually be `address(this)` so sale
proceeds remain inside MetaWallet and can be reinvested by hooks.

Implementation requirements:

- require Midnight is configured;
- pass `taker = address(this)`;
- require `units > 0`;
- return the two values from `Midnight.take`;
- emit `MidnightOfferTaken(id, units, buyerAssets, sellerAssets)`.

### 7.3 `onSell` Callback Flow

When MetaWallet is seller and `offer.callback = address(metaWallet)`, Midnight
calls:

```solidity
onSell(id, market, sellerAssets, units, pendingFeeDecrease, seller, receiver, data)
```

The module should:

1. Require `msg.sender == configuredMidnight`.
2. Require `seller == address(this)`.
3. Decode `SellCallbackData`.
4. Require `id == expectedMarketId`.
5. If `expectedReceiver != address(0)`, require `receiver == expectedReceiver`.
6. Return `CALLBACK_SUCCESS`.

The sell callback should not need to approve Midnight, because Midnight is
paying loan tokens to the seller receiver and reducing the seller's credit.

Reference implementation shape:

```solidity
function onSell(
    bytes32 id,
    Market memory market,
    uint256 sellerAssets,
    uint256,
    uint256,
    address seller,
    address receiver,
    bytes memory data
) external nonReentrant returns (bytes32) {
    MidnightModuleStorage storage $ = _getMidnightModuleStorage();
    require(msg.sender == $.midnight, MIDNIGHT_ONLY_MIDNIGHT);
    require(seller == address(this), MIDNIGHT_INVALID_SELLER);

    SellCallbackData memory callbackData = abi.decode(data, (SellCallbackData));
    require(id == callbackData.expectedMarketId, MIDNIGHT_INVALID_MARKET);
    if (callbackData.expectedReceiver != address(0)) {
        require(receiver == callbackData.expectedReceiver, MIDNIGHT_INVALID_RECEIVER);
    }
    if (callbackData.minFinalLoanTokenBalance != 0) {
        uint256 finalBalance = IERC20(market.loanToken).balanceOf(address(this));
        require(finalBalance >= callbackData.minFinalLoanTokenBalance, MIDNIGHT_INSUFFICIENT_LIQUIDITY);
    }

    emit MidnightSellCallbackValidated(id, sellerAssets, receiver);
    return CALLBACK_SUCCESS;
}
```

## 8. Accounting Requirements

Midnight credit is not idle vault liquidity.

After a lender fill, MetaWallet's direct loan-token balance decreases and its
Midnight credit increases. `VaultModule.totalIdle()` only sees actual token
balance, so the Midnight credit position must be accounted for through manager
settlement.

The manager should include Midnight credit positions in `virtualTotalAssets`
using a valuation policy. For v1, the Merkle root can aggregate Midnight
exposure under one strategy address, such as:

```solidity
strategy = address(midnightModule);
value = markedValueOfAllMidnightCredits;
```

The valuation policy should consider:

- face value of credit units;
- current market discount/exit price, if available;
- pending fees;
- realized loss factor;
- maturity and overdue/liquidation risk.

The module should not directly mutate `virtualTotalAssets`. It should expose
enough events and view helpers for the manager or offchain accounting process to
settle the vault accurately.

## 9. Security Requirements

### 9.1 Access Control

Admin-gated functions:

- `setMidnightConfig`
- `setMidnightAuthorization`
- `ratifyOfferTree`
- `cancelOfferGroup`
- `setIdleLiquidityCap`
- `setLiquidationQueue`
- `clearLiquidationQueue`

Executor-gated or admin/executor-gated functions:

- `withdrawCredits`
- `takeOffer`

Public callback functions:

- `onBuy`
- `onSell`

Callback functions must be callable by Midnight only.

### 9.2 Reentrancy

`onBuy` performs external calls to liquidation targets and then approves
Midnight. It should be protected by a non-reentrant guard compatible with
MetaWallet storage.

The design should account for the fact that `onBuy` is called in the middle of
`Midnight.take`. If a liquidation target can reenter MetaWallet, registry and
role checks must still hold.

### 9.3 Market Binding

Callback data must include `expectedMarketId`.

The callback should reject mismatched market ids. This prevents a valid
MetaWallet callback from being replayed across markets with the same loan token
but different maturity, gates, collateral, or risk parameters.

### 9.4 Queue Safety

The module should reject malformed queue steps:

- zero target;
- invalid amount placeholder offset;
- empty calldata;
- zero `maxLiquidationAmount`;
- disabled step where all fields are non-zero, if the implementation chooses to
  enforce clean disabled entries.

Queue execution should revert if a step fails. Continuing after a failed
liquidation would hide solvency problems and could leave the Midnight fill
unfunded.

### 9.5 Registry Policy

The registry must allow every external liquidation target and selector used by
the queue. Examples:

- ERC-4626 vault `withdraw(uint256,address,address)`;
- strategy adapter liquidation functions that accept a desired output amount;
- swap router selector, if a step includes a router call;
- any strategy adapter selector used in future versions.

Registry policy should be as narrow as possible. It should prefer exact target
and selector allow-lists, and where supported, parameter restrictions for
receiver and owner fields set to `address(metaWallet)`.

## 10. Example Flows

### 10.1 Idle-Balance Fill

1. MetaWallet has enough loan tokens idle.
2. Admin sets `idleLiquidityCap[loanToken] >= buyerAssets`.
3. Taker fills lender offer.
4. Midnight calls `onBuy`.
5. `onBuy` sees capped idle balance covers `buyerAssets`.
6. Queue is skipped.
7. MetaWallet approves Midnight for exactly `buyerAssets`.
8. Midnight pulls funds and mints credit to MetaWallet.

### 10.2 ERC-4626-Funded Fill

1. MetaWallet loan tokens are invested in an ERC-4626 vault.
2. Admin sets a small or zero idle cap for the loan token.
3. Admin queue contains a step calling `vault.withdraw(amount, metaWallet, metaWallet)`.
4. Taker fills lender offer.
5. `onBuy` computes the capped-idle deficit.
6. The module patches the deficit into the withdraw calldata.
7. The registry authorizes the vault withdrawal.
8. The ERC-4626 vault sends loan tokens back to MetaWallet.
9. The module approves Midnight for the fill amount.
10. Midnight pulls funds and credits MetaWallet.

### 10.3 Multi-Source Fill

1. MetaWallet has partial idle loan-token balance.
2. Admin sets `idleLiquidityCap` below the full idle balance.
3. `onBuy` treats only the capped amount as usable and records the rest as
   protected idle.
4. Queue step 0 withdraws from Strategy A but only covers part of the deficit.
5. Queue step 1 withdraws from Strategy B and finishes funding the fill.
6. The queue stops immediately after the fill is funded plus protected idle.
7. After Midnight pulls `buyerAssets`, protected idle remains in MetaWallet.
8. Remaining strategies are untouched.

### 10.4 Early Credit Sale

1. MetaWallet holds Midnight credit.
2. MetaWallet finds or publishes demand for that credit.
3. MetaWallet sells credit via a reduce-only sell offer or by taking a buy
   offer.
4. Midnight reduces MetaWallet credit and sends loan tokens to MetaWallet.
5. MetaWallet can keep proceeds idle or reinvest them through normal hooks.

## 11. Test Plan

Tests should follow the existing production-like deployment style:

1. Deploy MetaWallet implementation and proxy.
2. Install `VaultModule`.
3. Install existing hooks.
4. Install `MidnightModule` selectors.
5. Configure the registry.
6. Configure Midnight, SetterRatifier, and liquidation queues.

Required positive tests:

- idle-balance-only `onBuy` fill where cap covers `buyerAssets`;
- capped-idle fill where only part of MetaWallet's idle balance may be used and
  the protected idle remains after the Midnight pull;
- ERC-4626 `withdraw` queue fill;
- adapter-backed queue fill for strategies that cannot withdraw by desired
  output amount directly;
- multi-step fill where the first source is partial and the second completes the
  deficit;
- `withdrawCredits` after simulated repayment creates withdrawable liquidity;
- early credit sale through `takeOffer`;
- maker-side reduce-only sell offer callback through `onSell`.

Required negative tests:

- callback from non-Midnight caller;
- `onBuy` where `buyer != address(metaWallet)`;
- `onSell` where `seller != address(metaWallet)`;
- mismatched expected market id;
- full queue executed but final balance is insufficient;
- full queue executed but final balance does not preserve protected idle;
- malformed placeholder offset;
- registry rejection of a liquidation call;
- queue step target revert;
- final balance below `minFinalLoanTokenBalance`;
- unauthorized caller attempts to update config or queue.

The test suite should run:

```sh
forge fmt
forge build --use $(which solx)
forge test --match-path 'test/*Midnight*.t.sol' --use $(which solx)
```

## 12. Implementation Notes

This document is a specification, not an implementation. When implementing it,
prefer adding the module and interfaces in small steps:

1. Add Midnight interfaces and module storage.
2. Add config, authorization, ratification, and queue management.
3. Add idle liquidity cap management.
4. Add `onBuy` with capped-idle funding.
5. Add queue execution and calldata patching.
6. Add credit withdrawal.
7. Add early credit sale.
8. Add focused tests at each step.

Follow existing MetaWallet patterns:

- module selectors through `IModule`;
- ERC-7201 namespaced storage;
- admin checks using the same role storage as `MetaWallet`;
- registry authorization for low-level external calls;
- exact approvals and approval reset/retry patterns where needed.
