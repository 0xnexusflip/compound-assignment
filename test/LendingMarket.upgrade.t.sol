// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {LendingMarket} from "../src/LendingMarket.sol";
import {TransparentUpgradeableProxy} from "../src/TransparentUpgradeableProxy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {LendingMarketLegacy} from "./legacy/LendingMarketLegacy.sol";

/**
 * @notice Rehearses the production upgrade. The proxy starts on the implementation that is live
 *         today, accumulates real positions, then is pointed at the fixed implementation. Every
 *         balance must survive unchanged and every fix must be active immediately, with no
 *         reinitializer call.
 */
contract LendingMarketUpgradeTest is Test {
    uint256 internal constant RATE_PER_SECOND = uint256(0.05e18) / 365 days;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal supplier = makeAddr("supplier");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    MockERC20 internal base;
    MockERC20 internal weth;
    MockOracle internal wethOracle;

    TransparentUpgradeableProxy internal proxy;
    LendingMarketLegacy internal legacy;
    LendingMarket internal market;

    function setUp() public {
        base = new MockERC20("Base USD", "bUSD", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wethOracle = new MockOracle(2_000e18);

        LendingMarketLegacy impl = new LendingMarketLegacy();
        bytes memory initData = abi.encodeCall(
            LendingMarketLegacy.initialize,
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
        proxy = new TransparentUpgradeableProxy(address(impl), admin, initData);
        legacy = LendingMarketLegacy(address(proxy));
        market = LendingMarket(address(proxy));

        // Live state: a supplier, a borrower with open debt, and a year of accrual.
        base.mint(supplier, 1_000_000e18);
        vm.startPrank(supplier);
        base.approve(address(proxy), type(uint256).max);
        legacy.supply(1_000_000e18);
        vm.stopPrank();

        weth.mint(borrower, 10e18);
        vm.startPrank(borrower);
        weth.approve(address(proxy), type(uint256).max);
        legacy.supplyCollateral(10e18);
        legacy.borrow(15_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        legacy.accrueInterest();
    }

    function _upgrade() internal {
        LendingMarket newImpl = new LendingMarket();
        vm.prank(admin);
        proxy.upgradeTo(address(newImpl));
    }

    function test_upgrade_preservesEveryBalanceAndParameter() public {
        uint256 supplyBefore = legacy.supplyBalanceOf(supplier);
        uint256 debtBefore = legacy.borrowBalanceOf(borrower);
        uint256 collateralBefore = legacy.collateralBalance(borrower);
        uint256 borrowIndexBefore = legacy.baseBorrowIndex();
        uint256 supplyIndexBefore = legacy.baseSupplyIndex();

        _upgrade();

        assertEq(market.admin(), admin);
        assertEq(market.pauseGuardian(), guardian);
        assertEq(address(market.oracle()), address(wethOracle));
        assertEq(address(market.baseToken()), address(base));
        assertEq(address(market.collateralToken()), address(weth));
        assertEq(market.collateralFactor(), 0.8e18);
        assertEq(market.liquidationIncentive(), 1.1e18);
        assertEq(market.borrowRatePerSecond(), RATE_PER_SECOND);
        assertEq(market.baseBorrowIndex(), borrowIndexBefore);
        assertEq(market.baseSupplyIndex(), supplyIndexBefore);
        assertEq(market.supplyBalanceOf(supplier), supplyBefore);
        assertEq(market.borrowBalanceOf(borrower), debtBefore);
        assertEq(market.collateralBalance(borrower), collateralBefore);
        assertEq(market.totalCollateral(), collateralBefore);
        assertFalse(market.paused());

        // The appended slot reads as the default, so staleness protection is live at once.
        assertEq(market.maxPriceAge(), 1 days);
    }

    function test_upgrade_cannotBeReinitialized() public {
        _upgrade();

        vm.expectRevert("already initialized");
        market.initialize(
            address(this), address(this), address(wethOracle), address(base), address(weth), 1e18, 1e18, 0
        );
    }

    function test_upgrade_closesLiquidationOverSeizure() public {
        wethOracle.setPrice(1_500e18); // 12,000 of borrowing power against ~15,750 of debt
        base.mint(liquidator, 2_000e18);
        vm.prank(liquidator);
        base.approve(address(proxy), type(uint256).max);

        // On the live code, 1,000 of repayment takes every WETH the borrower has.
        uint256 snapshot = vm.snapshotState();
        vm.prank(liquidator);
        legacy.liquidate(borrower, 1_000e18);
        assertEq(weth.balanceOf(liquidator), 10e18, "legacy over-seizure must reproduce");
        vm.revertToState(snapshot);

        _upgrade();

        vm.prank(liquidator);
        market.liquidate(borrower, 1_000e18);
        assertEq(weth.balanceOf(liquidator), (1_000e18 * uint256(1.1e18)) / 1_500e18);
    }

    function test_upgrade_removesGuardianOracleControl() public {
        MockOracle rogue = new MockOracle(1);

        uint256 snapshot = vm.snapshotState();
        vm.prank(guardian);
        legacy.setOracle(address(rogue));
        assertEq(address(legacy.oracle()), address(rogue), "legacy guardian repricing must reproduce");
        vm.revertToState(snapshot);

        _upgrade();

        vm.prank(guardian);
        vm.expectRevert("not admin");
        market.setOracle(address(rogue));
    }

    function test_upgrade_appliesStalenessToExistingPositions() public {
        _upgrade();

        // The feed was last written in setUp, over a year ago.
        vm.prank(borrower);
        vm.expectRevert("stale price");
        market.borrow(1e18);

        wethOracle.setPrice(2_000e18);
        vm.prank(borrower);
        market.borrow(1e18);
    }
}
