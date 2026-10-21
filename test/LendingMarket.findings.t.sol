// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {LendingMarket} from "../src/LendingMarket.sol";
import {TransparentUpgradeableProxy} from "../src/TransparentUpgradeableProxy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

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
            (admin, guardian, address(wethOracle), address(base), address(weth), 0.80e18, 1.10e18, RATE_PER_SECOND)
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

        uint256 expectedSeize = (1_000e18 * uint256(1.10e18)) / 1_800e18;
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
        // The uncovered remainder stays on the books as bad debt rather than being gifted away.
        assertApproxEqAbs(market.borrowBalanceOf(borrower), 15_000e18 - paid, 1e6);
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
}
