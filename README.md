# LendingMarket

Single-collateral money market. Suppliers deposit the base asset and earn interest, borrowers post collateral and draw the base asset against it, and positions that fall below their borrowing power can be liquidated.

## Running it

The project is self-contained. `forge-std` is vendored under `lib/`, so no network access or `forge install` is needed.

```bash
forge build
forge test
forge test -vvv --match-test <name>     # a single test, with traces
```

Requires Foundry. If you do not have it: `curl -L https://foundry.paradigm.xyz | bash && foundryup`

## Layout

```
src/
  LendingMarket.sol                 the implementation, and the only file you need to change
  TransparentUpgradeableProxy.sol   the proxy the market is deployed behind
  interfaces/                       IERC20, IPriceOracle (Chainlink-style aggregator)
  mocks/                            test doubles for the base asset, collateral and oracle
script/
  Deploy.s.sol                      staging deployment, mirrors the production topology
test/
  LendingMarket.t.sol               the suite the market ships with today
  LendingMarket.findings.t.sol      one failing-then-passing test per finding below
  LendingMarket.upgrade.t.sol       upgrade rehearsal from the live implementation to this one
  legacy/LendingMarketLegacy.sol    renamed copy of the live implementation, test fixture only
  mocks/FalseReturnERC20.sol        token that returns false instead of reverting
  invariant/                        stateful properties under random action sequences
```

## How it works

**Accounting.** Supplier and borrower balances are stored as *principal* and scaled by two global indices, `baseSupplyIndex` and `baseBorrowIndex`. `accrueInterest()` advances both to the current timestamp. Present value is `principal * index / 1e18`, so a balance grows without anyone touching per-account storage.

**Scaling.** Everything is 1e18 fixed point unless stated otherwise. The oracle quotes the collateral in base-asset terms, also 1e18. So with WETH at 2,000 base, `getPrice()` returns `2000e18`.

**Borrowing power.** `collateralBalance * price * collateralFactor`, all 1e18 scaled. A position is healthy while its borrowing power covers its debt. `isHealthy()` is the single source of truth for this, and it is checked on any path that increases risk.

**Liquidation.** Once a position is unhealthy, anyone may repay part of its debt and receive collateral in exchange, plus the liquidation incentive. The incentive is 1e18 scaled and always at or above par, so `1.10e18` means the liquidator receives 110% of what they repaid, valued in collateral.

**Deployment.** The market is an implementation behind a `TransparentUpgradeableProxy`. All market state lives in the proxy's storage, which is why any change you make has to be layout-compatible with what is already deployed. The admin owns upgrades and risk parameters. A separate pause guardian exists so the market can be stopped quickly without reaching for the admin key.

## Roles

| Role | Held by | Remit |
|---|---|---|
| `admin` | governance timelock | upgrades, risk parameters, wiring |
| `pauseGuardian` | operations multisig | stopping the market in an incident |

The split matters. The guardian key is warmer and held by more people than the admin key, so anything the guardian can reach should be limited to stopping the market, not changing how it prices or values anything.

## Listed markets

See `script/Deploy.s.sol` for the current staging configuration.

## Findings

Eleven defects, numbered in the order I found them. Each one has a test in `test/LendingMarket.findings.t.sol` that fails against the implementation that is live today and passes against the fixed one. `test/LendingMarket.upgrade.t.sol` reproduces the two worst ones on the live code, upgrades the proxy, and shows them closed. `test/invariant/` holds four stateful properties checked under random sequences of every user action, time, price moves and donations. Totals equal account sums. Collateral is fully backed. Supplier claims are covered by cash plus debt. The supply index never outruns the borrow index.

| ID | Severity | Title | Where |
|---|---|---|---|
| F-1 | Critical | Liquidation seizes collateral in base units | `liquidate` |
| F-2 | High | The pause guardian can replace the price oracle | `setOracle` |
| F-3 | High | Oracle answers are used unchecked | `getPrice` |
| F-4 | Medium | Collateral withdrawal checks health against unaccrued debt | `withdrawCollateral` |
| F-5 | Medium | Token transfer return values are ignored | every transfer |
| F-6 | Low | Principal rounds in the caller's favor on withdraw and borrow | `withdraw`, `borrow` |
| F-7 | Medium | The supply index can be inflated when supply is tiny | `accrueInterest`, `supply` |
| F-8 | Low | A full repayment can leave one unit of principal behind | `repay`, `liquidate` |
| F-9 | Low | The pause guardian can also unpause | `setPaused` |
| F-10 | Medium | Bad debt keeps accruing interest to suppliers | `liquidate`, `accrueInterest` |
| F-11 | Low | A pause blocks collateral top-ups | `supplyCollateral` |

### F-1 Critical. Liquidation seizes collateral in base units

`seizeAmount` was `repayAmount * liquidationIncentive / 1e18`. That is a base amount, and the code handed it out as a collateral amount. The oracle price never entered the calculation.

**Exploit.** With the staging parameters (WETH at 2,000, factor 0.80, incentive 1.10), a borrower holds 10 WETH against 15,000 of debt. WETH drops to 1,800 and the position is unhealthy. A liquidator repays 9.1 base and the market computes a seizure of 10.01 WETH, capped to the borrower's whole 10 WETH, worth 18,000. Every unhealthy position loses all of its collateral to the first liquidator for a few units of base. A borrower can also do this to itself with a second address and drain the base supply round after round. The shipped test only asserted that the liquidator received more than zero.

**Fix.** Convert at the oracle price: `seizeAmount = repayAmount * liquidationIncentive / price`. When the position cannot cover the request, the repayment now shrinks to the value of the collateral that is left, rounded up. The liquidator never overpays. The uncovered debt stays on the books as bad debt instead of being gifted away.

**Tests.** `test_liquidate_seizesCollateralValuedAtOraclePrice`, `test_liquidate_capsRepaymentToCollateralValue`, `testFuzz_liquidate_seizeIsWorthRepaidValuePlusIncentive`, `test_upgrade_closesLiquidationOverSeizure`.

### F-2 High. The pause guardian can replace the price oracle

`setOracle` carried `onlyGuardian`. The README defines the guardian as the warm operations key whose only remit is to stop the market. A guardian key, or anyone who compromises it, could point the market at an oracle under their control. They could then borrow the whole base supply against one wei of collateral. They could also liquidate every healthy borrower and restore the oracle afterwards.

**Fix.** `setOracle` is `onlyAdmin`. It also refuses an oracle whose `decimals()` is not 18, because every valuation in the contract assumes the 1e18 scale.

**Tests.** `test_setOracle_revertsForGuardian`, `test_upgrade_removesGuardianOracleControl`.

### F-3 High. Oracle answers are used unchecked

`getPrice` cast `answer` to `uint256` and returned it. A negative answer becomes a price near 2^256, so `isHealthy` reports unbounded borrowing power for any account with 1 wei of collateral. A zero answer makes every borrower liquidatable. A stalled feed keeps pricing collateral at the last written value, so liquidations fire late or against the wrong accounts.

**Fix.** `getPrice` requires `answer > 0` and `block.timestamp - updatedAt <= maxPriceAge()`. The maximum age lives in a new storage slot appended after the live layout. Zero in that slot means the one-day default. The upgraded proxy is protected the moment it points at the new implementation, with no reinitializer and no window between two transactions. The admin can tune it with `setMaxPriceAge`. The paths that never read the price, `repay`, `supply` and `withdraw`, keep working while the feed is stale, so nobody is trapped.

**Tests.** `test_borrow_revertsOnNegativeOracleAnswer`, `test_liquidate_revertsOnZeroOracleAnswer`, `test_borrow_revertsOnStaleOracleAnswer`, `test_repay_worksWhileOracleIsStale`, `test_setMaxPriceAge_onlyAdmin`, `test_upgrade_appliesStalenessToExistingPositions`.

### F-4 Medium. Collateral withdrawal checks health against unaccrued debt

`withdrawCollateral` was the one risk-increasing path that did not call `accrueInterest()` first. The health check saw the debt as of the last accrual. After a year on a 15,000 borrow the real debt is 15,750 and needs 9.84 WETH, but the check still accepted 15,000 and let 0.5 WETH leave. The position is underwater as soon as anyone accrues.

**Fix.** `accrueInterest()` runs before the health check, the same as `borrow` and `liquidate`.

**Test.** `test_withdrawCollateral_accruesBeforeHealthCheck`.

### F-5 Medium. Token transfer return values are ignored

Every `transfer` and `transferFrom` discarded its boolean result. An asset that reports failure with `false` instead of a revert credits a supplier for tokens that never arrived. That supplier can then withdraw them against the deposits of everyone else. The listed WETH market uses a reverting token, so this is latent today. The market is upgradeable and new listings are a parameter change away.

**Fix.** All token movement goes through `_transferIn` and `_transferOut`, which require a true return. A revert still propagates as before.

**Test.** `test_supply_revertsWhenTransferFromReturnsFalse`.

### F-6 Low. Principal rounds in the caller's favor on withdraw and borrow

`withdraw` and `borrow` converted the amount to principal with floor division. Once an index is above 1e18, one wei converts to zero principal, so base leaves the market with no recorded balance change and no debt. Gas makes this unprofitable on its own. Combined with F-7, one principal unit can be worth thousands of base, and then every withdrawal below that value is free. The direction of every rounding step should favor the market.

**Fix.** `withdraw` and `borrow` round the principal up. `supply`, `repay` and `liquidate` already rounded in the market's favor and are unchanged.

**Tests.** `test_withdraw_roundsPrincipalAgainstTheCaller`, `test_borrow_roundsPrincipalAgainstTheCaller`.

### F-7 Medium. The supply index can be inflated when supply is tiny

`accrueInterest` hands suppliers `borrows * interest` and divides it by the supplied value. Nothing kept borrows at or below supplies, because base can be donated to the contract and then borrowed against collateral. With 1 wei supplied, 1,000,000 donated and borrowed, and 30 days of accrual, the supply index reaches 4.1e39. One principal unit is then worth 41,095 base, and a 30,000 deposit converts to zero principal and is absorbed. The attacker's own interest paid is the only cost.

This needs a market with almost no supply, so on the live market it is a Medium. It is a High on a fresh or drained market, and the live market can drain.

**Fix.** Only the supplied value earns interest: `earning = min(borrows, supplies)`, so the supply index can never grow faster than the borrow index. `supply` also rejects a deposit that converts to zero principal.

**Tests.** `test_accrueInterest_supplyIndexNeverOutrunsBorrowIndex`, `test_supply_revertsWhenPrincipalRoundsToZero`.

### F-8 Low. A full repayment can leave one unit of principal behind

`repay` caps the amount at `owed`, which rounds down, and then converts it back to principal, which rounds down again. One unit of principal survives and shows as 1 wei of debt. That wei can never be repaid, because 1 wei converts to 0 principal. A position with any debt can never withdraw the last of its collateral. The shipped `test_repayClearsTheDebt` passed only because the index was still exactly 1e18.

**Fix.** When the repayment covers the whole debt, the whole principal is cleared. `liquidate` gets the same treatment.

**Test.** `test_repay_fullRepaymentClearsPrincipal`.

### F-9 Low. The pause guardian can also unpause

`setPaused(false)` accepted the guardian. The README limits the guardian to stopping the market. A guardian signer could undo an admin pause in the next block during an incident.

**Fix.** Unpausing requires the admin. The guardian can still pause.

**Test.** `test_setPaused_guardianCannotUnpause`.

### F-10 Medium. Bad debt keeps accruing interest to suppliers

When a liquidation exhausts the collateral, the uncovered remainder of the debt stayed in `borrowPrincipal` and `totalBorrowPrincipal`. Nothing ever removed it. `accrueInterest` then kept crediting suppliers with interest on debt that nobody will ever pay. Supplier claims grew against an asset that does not exist, the hole grew every second, and the last supplier to withdraw carried all of it.

**Exploit.** Two suppliers hold 1,000,000 and 100,000. A borrower with 10 WETH owes 15,000 when WETH falls to 1,000. The liquidator takes the 10 WETH for 9,090.91 and 5,909.09 of debt remains with zero collateral. Five years later that debt reads 7,386.36 and supplier claims exceed the base held by the same amount. The first supplier withdraws in full. The second cannot.

**Fix.** When a liquidation leaves no collateral, the remaining debt is zeroed and subtracted from the borrow total. It is added to a new `badDebt` slot appended after `_maxPriceAge`, and an event records it. The loss is visible and stops compounding. Who absorbs it, suppliers pro rata or a reserve, is a governance decision I did not make.

**Test.** `test_liquidate_writesOffUncoveredDebt`.

### F-11 Low. A pause blocks collateral top-ups

`supplyCollateral` carried `whenNotPaused`. Adding collateral can only reduce risk. During a pause a borrower could not defend a position while interest kept accruing and the price kept moving. After the unpause, liquidators act first.

**Fix.** `supplyCollateral` works while paused. `liquidate` stays paused, see the note below.

**Test.** `test_supplyCollateral_worksWhilePaused`.

## Shipping it to the live proxy

The storage layout is unchanged in slots 0 to 17. Two variables are appended: `_maxPriceAge` at slot 18 and `badDebt` at slot 19. No variable was removed, reordered or retyped, and no reinitializer is needed. Verified with:

```bash
forge build --extra-output storageLayout
forge inspect LendingMarketLegacy storage-layout   # the live code, kept under test/legacy/
forge inspect LendingMarket storage-layout         # the fixed code
```

`test/LendingMarket.upgrade.t.sol` deploys the live implementation behind the proxy, opens real positions, and accrues a year of interest. It then calls `upgradeTo` and asserts that every balance, index and parameter survives and that each fix is active at once.

Deployment is one timelock transaction: deploy the new `LendingMarket` and call `upgradeTo` on the proxy. Optionally follow with `setMaxPriceAge` tuned to the production feed's heartbeat. Every existing external function signature is unchanged. Three functions were added, `maxPriceAge()`, `setMaxPriceAge(uint256)` and the `badDebt()` getter, plus two events.

Warning: after the upgrade, `borrow`, `withdrawCollateral` and `liquidate` revert while the feed is older than the maximum age. That is the intended fail-closed behavior. Confirm the production feed's heartbeat is below one day before the upgrade, or set a larger age in the same timelock batch.

### Static analysis

Slither (75 detectors, `lib/`, `test/`, `script/` and `mocks/` filtered) reports no High. Its Medium items are triaged as follows. The strict equalities (`amount == owed`, `collateralBalance == 0`, `debt == 0`, `elapsed == 0`) are intentional. Each compares values derived by the same arithmetic. The divide-before-multiply hits are the index math itself and lose at most one wei per step, in the market's favor after F-6. The two inbound-transfer reentrancy flags had no gain path with the listed tokens, and the transfers now run after the state writes. The ignored `roundId` and `answeredInRound` fields are a deliberate choice, since the age check covers staleness for a Chainlink-style feed. Aderyn reports three High items, all in the proxy: Yul `return`, unchecked `delegatecall` and locked ether. That is the expected shape of a proxy and out of scope.

## Noted, not changed

- `setPaused` also blocks `liquidate` and `withdrawCollateral`. A pause during a price crash shields underwater borrowers and lets bad debt form for suppliers. Compound-style markets pause seizures separately. This is a design decision for the team.
- Recorded bad debt (F-10) is still carried by the last supplier out. Sharing it pro rata through the supply index, or funding a reserve, needs a governance decision.
- `initialize` applies none of the checks the setters enforce. It never runs again on the live proxy, so this only matters for a new market.
- One `collateralFactor` serves as both the borrow limit and the liquidation threshold. A borrower at the limit is liquidatable after one second of interest. A separate, higher liquidation threshold is standard.
- `setAdmin` is a single step with no event. A typo hands the market to a dead address. A two-step transfer is the standard fix. The proxy admin slot does not move with the market admin.
- `setParameters` allows a collateral factor of 100 percent and an unbounded liquidation incentive. Both are admin inputs behind the timelock, so I left the bounds to governance.
- There is no close factor. A liquidator may repay 100 percent of a position. Standard markets cap this near 50 percent.
- `initialize` is callable on the raw implementation contract. It has no `delegatecall` or `selfdestruct`, so the proxy is not affected. A constructor that sets `_initialized` would close it.
- `supplyCollateral` credits `amount`, not the received balance, so a fee-on-transfer collateral would be over-credited. No such token is listed.
- Interest is simple interest between accruals, not compounded per second. Frequent accruals compound, rare ones do not. It is a property of this index design.

## Scope note

I prioritized the paths that move value against a price, in this order: liquidation, oracle, health checks, token movement, then the index math. I deliberately left the design questions above to the team. I did not add a reserve factor, a close factor, a separate liquidation threshold or a two-step admin transfer.

I am unsure whether a one-day default price age fits the production feed. With more time I would read the heartbeat of the feed onchain and run the invariant suite under Medusa for hours instead of seconds. I would also measure gas against the live implementation.

AI tooling was used throughout. All fixes were validated with manual passes by me. One suggestion I rejected: adding a `reinitialize` step to set the maximum price age during the upgrade. The proxy has no `upgradeToAndCall`, so that leaves a window between two transactions in which the market runs unprotected. The zero-means-default fallback removes the window.
