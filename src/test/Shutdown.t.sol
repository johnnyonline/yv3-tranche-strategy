// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";

contract ShutdownTest is Setup {

    function setUp() public virtual override {
        super.setUp();
    }

    function test_shutdownCanWithdraw(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_emergencyWithdraw_maxUint(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // should be able to pass uint 256 max and not revert.
        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(type(uint256).max);

        // A tranche never leaves the vault ahead of the others
        assertEq(strategy.balanceOfAsset(), 0, "!idle");
        assertEq(strategy.valueOfVault(), _amount, "!valueOfVault");

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_shutdownJuniorStillCovers(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(trancheA, user, _amount);
        mintAndDepositIntoStrategy(trancheB, user, _amount);
        mintAndDepositIntoStrategy(trancheE, user, _amount);

        // Shutdown the most junior tranche and try to pull it out of the vault
        vm.startPrank(emergencyAdmin);
        trancheE.shutdownStrategy();
        trancheE.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();

        // The vault loses 10%
        skip(1 days);
        lose(_amount * 3 / 10);
        allowLoss(trancheE);
        report();

        // It still took the whole loss
        assertApproxEqAbs(trancheA.totalAssets(), _amount, 3, "!A");
        assertApproxEqAbs(trancheB.totalAssets(), _amount, 3, "!B");
        assertApproxEqAbs(trancheE.totalAssets(), _amount - _amount * 3 / 10, 6, "!E");
    }

}
