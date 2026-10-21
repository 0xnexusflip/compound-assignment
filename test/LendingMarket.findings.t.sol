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
}
