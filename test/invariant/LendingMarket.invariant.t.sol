// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {LendingMarket} from "../../src/LendingMarket.sol";
import {TransparentUpgradeableProxy} from "../../src/TransparentUpgradeableProxy.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockOracle} from "../../src/mocks/MockOracle.sol";
import {LendingMarketHandler} from "./LendingMarketHandler.sol";

/// @notice Stateful properties of the fixed market under random sequences of user actions.
contract LendingMarketInvariantTest is Test {
    uint256 internal constant RATE_PER_SECOND = uint256(0.05e18) / 365 days;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");

    MockERC20 internal base;
    MockERC20 internal weth;
    MockOracle internal oracle;
    LendingMarket internal market;
    LendingMarketHandler internal handler;

    function setUp() public {
        base = new MockERC20("Base USD", "bUSD", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new MockOracle(2_000e18);

        LendingMarket impl = new LendingMarket();
        bytes memory initData = abi.encodeCall(
            LendingMarket.initialize,
            (admin, guardian, address(oracle), address(base), address(weth), 0.8e18, 1.1e18, RATE_PER_SECOND)
        );
        market = LendingMarket(address(new TransparentUpgradeableProxy(address(impl), admin, initData)));

        handler = new LendingMarketHandler(market, base, weth, oracle);
        targetContract(address(handler));
    }

    function _sumPrincipals() internal view returns (uint256 supplyP, uint256 borrowP, uint256 collateral) {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address actor = handler.actors(i);
            supplyP += market.supplyPrincipal(actor);
            borrowP += market.borrowPrincipal(actor);
            collateral += market.collateralBalance(actor);
        }
    }

    /// @dev Every tracked total equals the sum over accounts.
    function invariant_totalsMatchAccountSums() public view {
        (uint256 supplyP, uint256 borrowP, uint256 collateral) = _sumPrincipals();
        assertEq(market.totalSupplyPrincipal(), supplyP);
        assertEq(market.totalBorrowPrincipal(), borrowP);
        assertEq(market.totalCollateral(), collateral);
    }

    /// @dev Collateral accounting never drifts from the tokens the market holds.
    function invariant_collateralIsFullyBacked() public view {
        assertEq(weth.balanceOf(address(market)), market.totalCollateral());
    }

    /// @dev Supplier claims are covered by cash plus outstanding debt.
    function invariant_supplierClaimsAreCovered() public view {
        uint256 claims = market.presentValueSupply(market.totalSupplyPrincipal());
        uint256 cash = base.balanceOf(address(market));
        uint256 debt = market.presentValueBorrow(market.totalBorrowPrincipal());
        assertLe(claims, cash + debt + 1e6);
    }

    /// @dev The supply index can never outrun the borrow index (F-7).
    function invariant_supplyIndexNeverOutrunsBorrowIndex() public view {
        assertLe(market.baseSupplyIndex(), market.baseBorrowIndex());
    }
}
