// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";

import {LendingMarket} from "../src/LendingMarket.sol";
import {TransparentUpgradeableProxy} from "../src/TransparentUpgradeableProxy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {LendingMarketLegacy} from "./legacy/LendingMarketLegacy.sol";

/// @notice Logs the gas of each hot path on the live implementation and on the fixed one.
contract LendingMarketGasTest is Test {
    uint256 internal constant RATE_PER_SECOND = uint256(0.05e18) / 365 days;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal supplier = makeAddr("supplier");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    MockERC20 internal base;
    MockERC20 internal weth;
    MockOracle internal oracle;

    function setUp() public {
        base = new MockERC20("Base USD", "bUSD", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new MockOracle(2_000e18);
    }

    function _deploy(address impl) internal returns (LendingMarket market) {
        bytes memory initData = abi.encodeCall(
            LendingMarket.initialize,
            (admin, guardian, address(oracle), address(base), address(weth), 0.8e18, 1.1e18, RATE_PER_SECOND)
        );
        market = LendingMarket(address(new TransparentUpgradeableProxy(impl, admin, initData)));
        base.mint(supplier, 1_000_000e18);
        base.mint(borrower, 100_000e18);
        base.mint(liquidator, 100_000e18);
        weth.mint(borrower, 100e18);
        address[3] memory users = [supplier, borrower, liquidator];
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            base.approve(address(market), type(uint256).max);
            weth.approve(address(market), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _flow(string memory label, LendingMarket market) internal {
        uint256 g;

        vm.prank(supplier);
        g = gasleft();
        market.supply(1_000_000e18);
        console2.log(label, "supply", g - gasleft());

        vm.prank(borrower);
        g = gasleft();
        market.supplyCollateral(10e18);
        console2.log(label, "supplyCollateral", g - gasleft());

        vm.warp(block.timestamp + 1 days);
        oracle.setPrice(2_000e18);
        vm.prank(borrower);
        g = gasleft();
        market.borrow(15_000e18);
        console2.log(label, "borrow", g - gasleft());

        vm.warp(block.timestamp + 1 days);
        oracle.setPrice(2_000e18);
        vm.prank(borrower);
        g = gasleft();
        market.repay(1_000e18);
        console2.log(label, "repay", g - gasleft());

        vm.warp(block.timestamp + 1 days);
        oracle.setPrice(2_000e18);
        vm.prank(borrower);
        g = gasleft();
        market.withdrawCollateral(1e18);
        console2.log(label, "withdrawCollateral", g - gasleft());

        oracle.setPrice(1_800e18);
        vm.prank(liquidator);
        g = gasleft();
        market.liquidate(borrower, 1_000e18);
        console2.log(label, "liquidate", g - gasleft());

        vm.prank(supplier);
        g = gasleft();
        market.withdraw(1_000e18);
        console2.log(label, "withdraw", g - gasleft());
    }

    function test_gas_legacy() public {
        _flow("legacy", _deploy(address(new LendingMarketLegacy())));
    }

    function test_gas_fixed() public {
        _flow("fixed ", _deploy(address(new LendingMarket())));
    }
}
