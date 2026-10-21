// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {LendingMarket} from "../../src/LendingMarket.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockOracle} from "../../src/mocks/MockOracle.sol";

/// @notice Drives the market with every user action, time, price moves and donations.
contract LendingMarketHandler is Test {
    LendingMarket public market;
    MockERC20 public base;
    MockERC20 public weth;
    MockOracle public oracle;

    address[] public actors;

    constructor(LendingMarket market_, MockERC20 base_, MockERC20 weth_, MockOracle oracle_) {
        market = market_;
        base = base_;
        weth = weth_;
        oracle = oracle_;
        for (uint256 i = 0; i < 4; i++) {
            address actor = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(actor);
            vm.startPrank(actor);
            base.approve(address(market), type(uint256).max);
            weth.approve(address(market), type(uint256).max);
            vm.stopPrank();
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function supply(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1, 1_000_000e18);
        base.mint(who, amount);
        vm.prank(who);
        market.supply(amount);
    }

    function withdraw(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        uint256 max = market.supplyBalanceOf(who);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(who);
        market.withdraw(amount);
    }

    function supplyCollateral(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1, 1_000e18);
        weth.mint(who, amount);
        vm.prank(who);
        market.supplyCollateral(amount);
    }

    function withdrawCollateral(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        uint256 max = market.collateralBalance(who);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(who);
        market.withdrawCollateral(amount);
    }

    function borrow(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1, 1_000_000e18);
        vm.prank(who);
        market.borrow(amount);
    }

    function repay(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        uint256 owed = market.borrowBalanceOf(who);
        if (owed == 0) return;
        amount = bound(amount, 1, owed * 2);
        base.mint(who, amount);
        vm.prank(who);
        market.repay(amount);
    }

    function liquidate(uint256 seed, uint256 targetSeed, uint256 amount) external {
        address who = _actor(seed);
        address target = _actor(targetSeed);
        uint256 owed = market.borrowBalanceOf(target);
        if (owed == 0) return;
        amount = bound(amount, 1, owed);
        base.mint(who, amount);
        vm.prank(who);
        market.liquidate(target, amount);
    }

    function warp(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 7 days);
        vm.warp(block.timestamp + seconds_);
        (, int256 answer,,,) = oracle.latestRoundData();
        oracle.setPrice(answer);
    }

    function movePrice(uint256 price) external {
        price = bound(price, 500e18, 5_000e18);
        oracle.setPrice(int256(price));
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 100_000e18);
        base.mint(address(market), amount);
    }
}
