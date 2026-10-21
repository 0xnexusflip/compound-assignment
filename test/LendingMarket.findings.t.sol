// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {LendingMarket} from "../src/LendingMarket.sol";
import {TransparentUpgradeableProxy} from "../src/TransparentUpgradeableProxy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {FalseReturnERC20} from "./mocks/FalseReturnERC20.sol";

/**
 * @notice One test per finding in the README. Each test fails against the implementation that is
 *         live today and passes against the fixed one.
 */
contract LendingMarketFindingsTest is Test {
    uint256 internal constant FACTOR = 1e18;
    uint256 internal constant RATE_PER_SECOND = uint256(0.05e18) / 365 days;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal supplier = makeAddr("supplier");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    MockERC20 internal base;
    MockERC20 internal weth;
    MockOracle internal wethOracle;

    LendingMarket internal market;

    function setUp() public {
        base = new MockERC20("Base USD", "bUSD", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wethOracle = new MockOracle(2_000e18);

        LendingMarket impl = new LendingMarket();
        bytes memory initData = abi.encodeCall(
            LendingMarket.initialize,
            (
                admin,
                guardian,
                address(wethOracle),
                address(base),
                address(weth),
                0.8e18,
                1.1e18,
                RATE_PER_SECOND
            )
        );
        market = LendingMarket(address(new TransparentUpgradeableProxy(address(impl), admin, initData)));

        base.mint(supplier, 1_000_000e18);
        vm.startPrank(supplier);
        base.approve(address(market), type(uint256).max);
        market.supply(1_000_000e18);
        vm.stopPrank();
    }

    function _postCollateral(address who, uint256 amount) internal {
        weth.mint(who, amount);
        vm.startPrank(who);
        weth.approve(address(market), type(uint256).max);
        market.supplyCollateral(amount);
        vm.stopPrank();
    }

    function _fundLiquidator(uint256 amount) internal {
        base.mint(liquidator, amount);
        vm.prank(liquidator);
        base.approve(address(market), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------
    // F-1: liquidation seizes collateral in base units
    // ---------------------------------------------------------------------------------------

    /// @dev 10 WETH at 1,800 is 18,000 of collateral. Repaying 1,000 of debt must seize
    ///      1,000 * 1.10 / 1,800 = 0.6111 WETH, not the whole position.
    function test_liquidate_seizesCollateralValuedAtOraclePrice() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(15_000e18);

        wethOracle.setPrice(1_800e18);
        assertFalse(market.isHealthy(borrower));

        _fundLiquidator(1_000e18);
        vm.prank(liquidator);
        market.liquidate(borrower, 1_000e18);

        uint256 expectedSeize = (1_000e18 * uint256(1.1e18)) / 1_800e18;
        assertEq(weth.balanceOf(liquidator), expectedSeize, "seize must be priced in collateral units");
        assertEq(market.collateralBalance(borrower), 10e18 - expectedSeize);
        assertApproxEqAbs(market.borrowBalanceOf(borrower), 14_000e18, 1);
    }

    /// @dev The liquidator pays for exactly the collateral it receives. When the position cannot
    ///      cover the requested repayment, the repayment shrinks to what the collateral is worth.
    function test_liquidate_capsRepaymentToCollateralValue() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(15_000e18);

        // Collateral crashes to 10,000 of value, below the 15,000 debt.
        wethOracle.setPrice(1_000e18);

        _fundLiquidator(15_000e18);
        vm.prank(liquidator);
        market.liquidate(borrower, 15_000e18);

        // Whole collateral seized, liquidator paid 10,000 / 1.10 = 9,090.9 for it.
        uint256 paid = 15_000e18 - base.balanceOf(liquidator);
        assertEq(weth.balanceOf(liquidator), 10e18);
        assertApproxEqAbs(paid, uint256(10e18 * 1_000e18) / uint256(1_100_000_000_000_000_000), 1e6);
        assertEq(market.collateralBalance(borrower), 0);
        // The uncovered remainder is written off and recorded rather than being gifted away (F-10).
        assertEq(market.borrowBalanceOf(borrower), 0);
        assertApproxEqAbs(market.badDebt(), 15_000e18 - paid, 1e6);
    }

    // ---------------------------------------------------------------------------------------
    // F-2: the pause guardian can replace the price oracle
    // ---------------------------------------------------------------------------------------

    /// @dev The README limits the guardian to stopping the market. Repricing is an admin power.
    function test_setOracle_revertsForGuardian() public {
        MockOracle rogue = new MockOracle(2_000_000e18);

        vm.prank(guardian);
        vm.expectRevert("not admin");
        market.setOracle(address(rogue));

        vm.prank(admin);
        market.setOracle(address(rogue));
        assertEq(address(market.oracle()), address(rogue));
    }

    // ---------------------------------------------------------------------------------------
    // F-3: oracle answers are used unchecked
    // ---------------------------------------------------------------------------------------

    /// @dev A negative answer cast to uint256 becomes a price near 2^256, which turns 1 wei of
    ///      collateral into unbounded borrowing power. Risk-increasing paths must refuse it.
    function test_borrow_revertsOnNegativeOracleAnswer() public {
        _postCollateral(borrower, 1);
        wethOracle.setPrice(-1);

        vm.prank(borrower);
        vm.expectRevert("invalid price");
        market.borrow(1_000_000e18);
    }

    /// @dev A zero answer must not be accepted either. It would make every borrower liquidatable.
    function test_liquidate_revertsOnZeroOracleAnswer() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(5_000e18);

        wethOracle.setPrice(0);

        _fundLiquidator(1_000e18);
        vm.prank(liquidator);
        vm.expectRevert("invalid price");
        market.liquidate(borrower, 1_000e18);
    }

    /// @dev A stalled feed must not keep pricing collateral. Borrowing against a stale price is
    ///      refused once the answer is older than the configured maximum age.
    function test_borrow_revertsOnStaleOracleAnswer() public {
        _postCollateral(borrower, 10e18);

        vm.warp(block.timestamp + market.maxPriceAge() + 1);

        vm.prank(borrower);
        vm.expectRevert("stale price");
        market.borrow(1_000e18);

        // A fresh answer restores the path.
        wethOracle.setPrice(2_000e18);
        vm.prank(borrower);
        market.borrow(1_000e18);
        assertEq(base.balanceOf(borrower), 1_000e18);
    }

    /// @dev Repaying never depends on the price, so a stalled feed must not trap borrowers.
    function test_repay_worksWhileOracleIsStale() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(1_000e18);

        base.mint(borrower, 10e18); // covers one day of interest
        vm.warp(block.timestamp + market.maxPriceAge() + 1);

        vm.startPrank(borrower);
        base.approve(address(market), type(uint256).max);
        market.repay(type(uint256).max);
        vm.stopPrank();
        assertEq(market.borrowBalanceOf(borrower), 0);
    }

    function test_setMaxPriceAge_onlyAdmin() public {
        vm.prank(guardian);
        vm.expectRevert("not admin");
        market.setMaxPriceAge(2 hours);

        vm.prank(admin);
        market.setMaxPriceAge(2 hours);
        assertEq(market.maxPriceAge(), 2 hours);
    }

    // ---------------------------------------------------------------------------------------
    // F-4: withdrawCollateral checks health against unaccrued debt
    // ---------------------------------------------------------------------------------------

    /// @dev 10 WETH backs a 15,000 borrow. After a year the debt is 15,750, which needs 9.84 WETH
    ///      of collateral. Without accrual the check still sees 15,000 and lets 0.5 WETH leave,
    ///      which leaves the position underwater the moment anyone accrues.
    function test_withdrawCollateral_accruesBeforeHealthCheck() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(15_000e18);

        vm.warp(block.timestamp + 365 days);
        wethOracle.setPrice(2_000e18);

        vm.prank(borrower);
        vm.expectRevert("would be undercollateralized");
        market.withdrawCollateral(0.5e18);

        market.accrueInterest();
        assertTrue(market.isHealthy(borrower), "position must still be healthy after accrual");
    }

    // ---------------------------------------------------------------------------------------
    // F-5: token transfer return values are ignored
    // ---------------------------------------------------------------------------------------

    /// @dev With a base asset that signals failure by returning false, a supplier is credited for
    ///      tokens that never arrived and can withdraw them against everyone else's deposits.
    function test_supply_revertsWhenTransferFromReturnsFalse() public {
        FalseReturnERC20 falseBase = new FalseReturnERC20();
        LendingMarket impl = new LendingMarket();
        bytes memory initData = abi.encodeCall(
            LendingMarket.initialize,
            (
                admin,
                guardian,
                address(wethOracle),
                address(falseBase),
                address(weth),
                0.8e18,
                1.1e18,
                RATE_PER_SECOND
            )
        );
        LendingMarket falseMarket =
            LendingMarket(address(new TransparentUpgradeableProxy(address(impl), admin, initData)));

        // Supplier holds nothing and approved nothing.
        vm.prank(supplier);
        vm.expectRevert("transfer failed");
        falseMarket.supply(1_000e18);

        assertEq(falseMarket.supplyBalanceOf(supplier), 0);
    }

    // ---------------------------------------------------------------------------------------
    // F-6: principal rounds in the user's favor on withdraw and borrow
    // ---------------------------------------------------------------------------------------

    /// @dev Once the supply index is above 1e18, withdrawing 1 wei converts to 0 principal, so the
    ///      supplier's recorded balance never moves while base leaves the market.
    function test_withdraw_roundsPrincipalAgainstTheCaller() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(10_000e18);

        vm.warp(block.timestamp + 365 days);
        market.accrueInterest();
        assertGt(market.baseSupplyIndex(), FACTOR);

        uint256 principalBefore = market.supplyPrincipal(supplier);
        vm.prank(supplier);
        market.withdraw(1);

        assertLt(market.supplyPrincipal(supplier), principalBefore, "withdraw must burn at least 1 principal");
    }

    /// @dev Same shape on the borrow side: 1 wei of debt converts to 0 principal, so the borrower
    ///      receives base with no recorded debt and no collateral.
    function test_borrow_roundsPrincipalAgainstTheCaller() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(10_000e18);

        vm.warp(block.timestamp + 365 days);
        wethOracle.setPrice(2_000e18);
        market.accrueInterest();

        address freeloader = makeAddr("freeloader");
        vm.prank(freeloader);
        vm.expectRevert("would be undercollateralized");
        market.borrow(1);
    }

    // ---------------------------------------------------------------------------------------
    // F-7: the supply index can be inflated when supply is tiny
    // ---------------------------------------------------------------------------------------

    function _emptyMarket() internal returns (LendingMarket fresh) {
        LendingMarket impl = new LendingMarket();
        bytes memory initData = abi.encodeCall(
            LendingMarket.initialize,
            (
                admin,
                guardian,
                address(wethOracle),
                address(base),
                address(weth),
                0.8e18,
                1.1e18,
                RATE_PER_SECOND
            )
        );
        fresh = LendingMarket(address(new TransparentUpgradeableProxy(address(impl), admin, initData)));
    }

    /// @dev Interest to suppliers is divided by the supplied value. With 1 wei supplied and a
    ///      donated balance borrowed against collateral, the supply index explodes, and the next
    ///      real deposit converts to zero principal. The supply index must never outrun the
    ///      borrow index.
    function test_accrueInterest_supplyIndexNeverOutrunsBorrowIndex() public {
        LendingMarket fresh = _emptyMarket();
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");

        base.mint(attacker, 1_000_001e18);
        weth.mint(attacker, 1_000e18);
        vm.startPrank(attacker);
        base.approve(address(fresh), type(uint256).max);
        weth.approve(address(fresh), type(uint256).max);
        fresh.supply(1);
        base.transfer(address(fresh), 1_000_000e18); // donation, not a supply
        fresh.supplyCollateral(1_000e18);
        fresh.borrow(1_000_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);
        fresh.accrueInterest();
        assertLe(fresh.baseSupplyIndex(), fresh.baseBorrowIndex(), "supply index outran borrow index");

        base.mint(victim, 30_000e18);
        vm.startPrank(victim);
        base.approve(address(fresh), type(uint256).max);
        fresh.supply(30_000e18);
        vm.stopPrank();
        assertApproxEqAbs(fresh.supplyBalanceOf(victim), 30_000e18, 1);
    }

    /// @dev A deposit that converts to zero principal must revert instead of being absorbed.
    function test_supply_revertsWhenPrincipalRoundsToZero() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(10_000e18);
        vm.warp(block.timestamp + 365 days);
        market.accrueInterest();

        base.mint(supplier, 1);
        vm.prank(supplier);
        vm.expectRevert("zero principal");
        market.supply(1);
    }

    // ---------------------------------------------------------------------------------------
    // F-8: a full repayment can leave one unit of principal behind
    // ---------------------------------------------------------------------------------------

    /// @dev owed rounds down, then the principal for owed rounds down again, so repay(max) can
    ///      leave 1 principal and 1 wei of debt. That wei can never be repaid, because 1 wei
    ///      converts to 0 principal, and the borrower can never free the last of the collateral.
    function test_repay_fullRepaymentClearsPrincipal() public {
        _postCollateral(borrower, 10e18);

        // Borrow at an index that is not 1e18 so the principal is not a round number.
        vm.warp(block.timestamp + 100 days);
        wethOracle.setPrice(2_000e18);
        vm.prank(borrower);
        market.borrow(10_000e18);

        vm.warp(block.timestamp + 265 days);
        base.mint(borrower, 1_000e18);
        vm.startPrank(borrower);
        base.approve(address(market), type(uint256).max);
        market.repay(type(uint256).max);
        vm.stopPrank();

        assertEq(market.borrowPrincipal(borrower), 0, "principal must be fully cleared");
        assertEq(market.borrowBalanceOf(borrower), 0);

        wethOracle.setPrice(2_000e18);
        vm.prank(borrower);
        market.withdrawCollateral(10e18);
        assertEq(weth.balanceOf(borrower), 10e18);
    }

    // ---------------------------------------------------------------------------------------
    // F-9: the pause guardian can also unpause
    // ---------------------------------------------------------------------------------------

    /// @dev The guardian's remit is stopping the market. Restarting it is an admin decision.
    function test_setPaused_guardianCannotUnpause() public {
        vm.prank(admin);
        market.setPaused(true);

        vm.prank(guardian);
        vm.expectRevert("not admin");
        market.setPaused(false);

        vm.prank(admin);
        market.setPaused(false);
        assertFalse(market.paused());

        vm.prank(guardian);
        market.setPaused(true);
        assertTrue(market.paused());
    }

    // ---------------------------------------------------------------------------------------
    // Property: liquidation value conservation
    // ---------------------------------------------------------------------------------------

    /// @dev For any unhealthy price and any requested repayment, the liquidator never pays more
    ///      than the collateral is worth, the seized collateral is worth at most the payment plus
    ///      the incentive, and a position that cannot pay the incentive is closed in full.
    function testFuzz_liquidate_seizeIsWorthRepaidValuePlusIncentive(uint256 price, uint256 repayAmount)
        public
    {
        price = bound(price, 1e18, 1_874e18); // unhealthy for 15,000 of debt on 10 WETH
        repayAmount = bound(repayAmount, 1e18, 15_000e18);

        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(15_000e18);
        wethOracle.setPrice(int256(price));

        _fundLiquidator(20_000e18);
        uint256 owed = market.borrowBalanceOf(borrower);
        uint256 collateralValue = (10e18 * price) / FACTOR;
        bool fullClose = 10e18 * price < owed * uint256(1.1e18);
        if (fullClose) {
            uint256 fullRepay = collateralValue >= owed
                ? owed
                : (collateralValue * FACTOR + uint256(1.1e18) - 1) / uint256(1.1e18);
            if (repayAmount < fullRepay) {
                vm.prank(liquidator);
                vm.expectRevert("underwater, close in full");
                market.liquidate(borrower, repayAmount);
                return;
            }
        }
        vm.prank(liquidator);
        market.liquidate(borrower, repayAmount);

        uint256 seized = weth.balanceOf(liquidator);
        uint256 paid = 20_000e18 - base.balanceOf(liquidator);
        uint256 seizedValue = (seized * price) / FACTOR;
        uint256 paidValue = (paid * uint256(1.1e18)) / FACTOR;

        assertLe(seized, 10e18);
        assertLe(paid, owed);
        if (fullClose) {
            assertEq(seized, 10e18, "underwater position must close in full");
            assertEq(market.collateralBalance(borrower), 0);
            assertEq(market.borrowBalanceOf(borrower), 0);
            if (collateralValue >= owed) {
                assertEq(paid, owed, "solvent collateral pays the whole debt");
                assertEq(market.badDebt(), 0);
            } else {
                assertApproxEqAbs(seizedValue, paidValue, price / FACTOR + 2);
                assertApproxEqAbs(market.badDebt(), owed - paid, 1);
            }
        } else {
            assertEq(paid, repayAmount);
            assertApproxEqAbs(seizedValue, paidValue, price / FACTOR + 2);
            assertEq(market.badDebt(), 0);
        }
    }

    // ---------------------------------------------------------------------------------------
    // F-10: bad debt keeps accruing interest to suppliers
    // ---------------------------------------------------------------------------------------

    /// @dev After a liquidation exhausts the collateral, the uncovered debt stays in the borrow
    ///      total and keeps paying interest to suppliers that nobody will ever pay. The hole grows
    ///      every second and the last supplier out eats all of it.
    function test_liquidate_writesOffUncoveredDebt() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(15_000e18);

        wethOracle.setPrice(1_000e18); // 10,000 of collateral against 15,000 of debt
        _fundLiquidator(15_000e18);
        vm.prank(liquidator);
        market.liquidate(borrower, 15_000e18);

        assertEq(market.collateralBalance(borrower), 0);
        assertEq(market.borrowBalanceOf(borrower), 0, "uncovered debt must be written off");
        assertApproxEqAbs(market.badDebt(), 15_000e18 - 9_090_909_090_909_090_909_090, 1e6);

        uint256 claimsBefore = market.supplyBalanceOf(supplier);
        vm.warp(block.timestamp + 5 * 365 days);
        market.accrueInterest();
        assertEq(market.supplyBalanceOf(supplier), claimsBefore, "no interest may accrue on bad debt");
    }

    // ---------------------------------------------------------------------------------------
    // F-11: a pause blocks collateral top-ups
    // ---------------------------------------------------------------------------------------

    /// @dev Adding collateral only reduces risk, so a paused market must still accept it.
    function test_supplyCollateral_worksWhilePaused() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(15_000e18);

        vm.prank(guardian);
        market.setPaused(true);

        weth.mint(borrower, 1e18);
        vm.prank(borrower);
        market.supplyCollateral(1e18);
        assertEq(market.collateralBalance(borrower), 11e18);
    }

    // ---------------------------------------------------------------------------------------
    // F-12: the full-close rule, from the verification pass on F-10
    // ---------------------------------------------------------------------------------------

    /// @dev 10 WETH at 1,600 is 16,000 against 15,000 of debt: solvent, but short of the 10
    ///      percent incentive. The liquidator must pay the whole debt for the collateral. Nothing
    ///      may be written off while the collateral still covers the debt.
    function test_liquidate_solventCollateralPaysWholeDebt() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(15_000e18);
        wethOracle.setPrice(1_600e18);

        _fundLiquidator(15_000e18);
        vm.prank(liquidator);
        market.liquidate(borrower, 15_000e18);

        assertEq(weth.balanceOf(liquidator), 10e18);
        assertEq(base.balanceOf(liquidator), 0, "liquidator pays the full 15,000");
        assertEq(market.badDebt(), 0, "nothing to write off");
        assertEq(market.borrowBalanceOf(borrower), 0);
    }

    /// @dev A liquidator cannot leave one wei of collateral behind to keep uncovered debt alive and
    ///      earning. An underwater position is closed in full whatever amount was requested.
    function test_liquidate_underwaterPositionCannotBeLeftWithDust() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(15_000e18);
        wethOracle.setPrice(1_000e18);

        _fundLiquidator(10_000e18);
        vm.prank(liquidator);
        vm.expectRevert("underwater, close in full");
        market.liquidate(borrower, 9_090_909_090_909_090_909_090); // would have seized 10e18 - 1

        vm.prank(liquidator);
        market.liquidate(borrower, 15_000e18);
        assertEq(market.collateralBalance(borrower), 0);
        assertEq(market.borrowBalanceOf(borrower), 0);
        assertGt(market.badDebt(), 0);
    }

    // ---------------------------------------------------------------------------------------
    // F-13: collateral factor times incentive is unbounded
    // ---------------------------------------------------------------------------------------

    /// @dev With 0.95 and 1.10 each inside its own bound, a position at the borrow limit cannot pay
    ///      the incentive out of its own collateral, and the gap would come from the suppliers.
    function test_setParameters_revertsWhenFactorTimesIncentiveAbovePar() public {
        vm.prank(admin);
        vm.expectRevert("cf times incentive above par");
        market.setParameters(0.95e18, 1.1e18, RATE_PER_SECOND);

        vm.prank(admin);
        market.setParameters(0.9e18, 1.1e18, RATE_PER_SECOND);
        assertEq(market.collateralFactor(), 0.9e18);
    }

    // ---------------------------------------------------------------------------------------
    // F-14: a compromised guardian cannot be replaced
    // ---------------------------------------------------------------------------------------

    function test_setPauseGuardian_adminCanReplaceGuardian() public {
        address newGuardian = makeAddr("newGuardian");

        vm.prank(guardian);
        vm.expectRevert("not admin");
        market.setPauseGuardian(newGuardian);

        vm.prank(admin);
        market.setPauseGuardian(newGuardian);
        assertEq(market.pauseGuardian(), newGuardian);

        vm.prank(guardian);
        vm.expectRevert("not guardian");
        market.setPaused(true);
    }

    // ---------------------------------------------------------------------------------------
    // F-15: branch test and seize math disagreed by one wei below a price of 1e18
    // ---------------------------------------------------------------------------------------

    /// @dev With collateral worth less than one base unit per unit, the rounded branch test could
    ///      pick the partial branch while the unrounded seize math exceeded the collateral, and the
    ///      full liquidation reverted on underflow.
    function test_liquidate_fullCloseAtSubUnitPrice() public {
        _postCollateral(borrower, 33_000e18 + 10);
        wethOracle.setPrice(1e18);
        vm.prank(borrower);
        market.borrow(15_000e18 + 5);

        // Collateral value 16,500 + 5 wei, within one wei of owed * 1.10 after rounding.
        wethOracle.setPrice(0.5e18);
        assertFalse(market.isHealthy(borrower));

        _fundLiquidator(20_000e18);
        vm.prank(liquidator);
        market.liquidate(borrower, 15_000e18 + 5);

        assertEq(market.collateralBalance(borrower), 0);
        assertEq(market.borrowBalanceOf(borrower), 0);
        assertEq(market.badDebt(), 0);
    }
}
