// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";

// Tranche B has a 14 day cooldown and a 7 day withdrawal window, tranche E a 30 day cooldown
contract CooldownTest is Setup {

    address public alice;
    address public bob;

    function setUp() public virtual override {
        super.setUp();

        // Fresh addresses, the low ones hold USDC on mainnet
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    function test_cooldownIsRequired() public {
        mintAndDepositIntoStrategy(trancheB, alice, 100e6);

        assertEq(trancheB.maxRedeem(alice), 0, "!maxRedeem");
        assertEq(trancheB.maxWithdraw(alice), 0, "!maxWithdraw");

        vm.prank(alice);
        vm.expectRevert("ERC4626: redeem more than max");
        trancheB.redeem(100e6, alice, alice);
    }

    function test_redeemAfterCooldown() public {
        mintAndDepositIntoStrategy(trancheB, alice, 100e6);

        vm.prank(alice);
        trancheB.startCooldown(100e6);

        (uint64 _cooldownEnd, uint64 _windowEnd, uint128 _shares) = trancheB.cooldowns(alice);
        assertEq(_cooldownEnd, block.timestamp + 14 days, "!cooldownEnd");
        assertEq(_windowEnd, block.timestamp + 21 days, "!windowEnd");
        assertEq(_shares, 100e6, "!shares");

        // Not yet
        skip(14 days - 1);
        assertEq(trancheB.maxRedeem(alice), 0, "!early");

        // Now
        skip(1);
        assertEq(trancheB.maxRedeem(alice), 100e6, "!maxRedeem");
        vm.prank(alice);
        trancheB.redeem(100e6, alice, alice);
        assertEq(asset.balanceOf(alice), 100e6, "!balance");

        // The cooldown is used up
        (_cooldownEnd, _windowEnd, _shares) = trancheB.cooldowns(alice);
        assertEq(_cooldownEnd, 0, "!cooldownEnd after");
        assertEq(_windowEnd, 0, "!windowEnd after");
        assertEq(_shares, 0, "!shares after");
    }

    function test_onlyCooledSharesAreRedeemable() public {
        mintAndDepositIntoStrategy(trancheB, alice, 300e6);

        vm.prank(alice);
        trancheB.startCooldown(100e6);
        skip(14 days);

        assertEq(trancheB.maxRedeem(alice), 100e6, "!maxRedeem");

        // A partial withdrawal uses up as much of the cooldown
        vm.prank(alice);
        trancheB.redeem(40e6, alice, alice);
        (,, uint128 _shares) = trancheB.cooldowns(alice);
        assertEq(_shares, 60e6, "!shares");

        vm.prank(alice);
        trancheB.redeem(60e6, alice, alice);
        assertEq(asset.balanceOf(alice), 100e6, "!balance");

        // The other 200 never cooled down
        assertEq(trancheB.maxRedeem(alice), 0, "!maxRedeem after");
        vm.prank(alice);
        vm.expectRevert("ERC4626: redeem more than max");
        trancheB.redeem(1, alice, alice);
    }

    function test_cooledSharesCannotBeTransferred() public {
        mintAndDepositIntoStrategy(trancheB, alice, 200e6);

        vm.prank(alice);
        trancheB.startCooldown(100e6);

        // The shares that are not cooling down can move
        vm.prank(alice);
        trancheB.transfer(bob, 100e6);
        assertEq(trancheB.balanceOf(bob), 100e6, "!bob");

        // The ones that are cannot
        vm.prank(alice);
        vm.expectRevert("!transfer");
        trancheB.transfer(bob, 1);

        // Not through an allowance either
        vm.prank(alice);
        trancheB.approve(bob, 1);
        vm.prank(bob);
        vm.expectRevert("!transfer");
        trancheB.transferFrom(alice, bob, 1);
    }

    function test_cancelCooldown() public {
        mintAndDepositIntoStrategy(trancheB, alice, 100e6);

        vm.prank(alice);
        trancheB.startCooldown(100e6);

        vm.prank(alice);
        trancheB.cancelCooldown();
        (,, uint128 _shares) = trancheB.cooldowns(alice);
        assertEq(_shares, 0, "!shares");

        // The shares can move again, but cannot be redeemed
        vm.prank(alice);
        trancheB.transfer(bob, 100e6);
        assertEq(trancheB.balanceOf(bob), 100e6, "!bob");

        skip(14 days);
        assertEq(trancheB.maxRedeem(bob), 0, "!maxRedeem");
    }

    function test_startCooldownAgain_replacesTheFirst() public {
        mintAndDepositIntoStrategy(trancheB, alice, 200e6);

        vm.prank(alice);
        trancheB.startCooldown(50e6);

        skip(3 days);
        vm.prank(alice);
        trancheB.startCooldown(120e6);

        (uint64 _cooldownEnd,, uint128 _shares) = trancheB.cooldowns(alice);
        assertEq(_shares, 120e6, "!shares");
        assertEq(_cooldownEnd, block.timestamp + 14 days, "!cooldownEnd");

        // The first cooldown would be over by now
        skip(11 days);
        assertEq(trancheB.maxRedeem(alice), 0, "!maxRedeem");
    }

    function test_cooldownGoesStaleAfterTheWindow() public {
        mintAndDepositIntoStrategy(trancheB, alice, 100e6);

        vm.prank(alice);
        trancheB.startCooldown(100e6);

        // Last second of the window
        skip(21 days);
        assertEq(trancheB.maxRedeem(alice), 100e6, "!maxRedeem");

        skip(1);
        assertEq(trancheB.maxRedeem(alice), 0, "!stale");
        vm.prank(alice);
        vm.expectRevert("ERC4626: redeem more than max");
        trancheB.redeem(100e6, alice, alice);

        // A stale cooldown no longer locks the shares
        vm.prank(alice);
        trancheB.transfer(bob, 100e6);
        assertEq(trancheB.balanceOf(bob), 100e6, "!bob");
    }

    function test_cooledSharesStayExposed() public {
        mintAndDepositIntoStrategy(trancheA, user, 800e6);
        mintAndDepositIntoStrategy(trancheB, alice, 100e6);
        mintAndDepositIntoStrategy(trancheE, bob, 100e6);

        vm.prank(bob);
        trancheE.startCooldown(100e6);

        // The vault loses 5% while E's shares cool down
        skip(1 days);
        lose(50e6);
        allowLoss(trancheE);
        report();

        // They paid the cover all the same, and leave with what is left
        skip(30 days);
        vm.prank(bob);
        trancheE.redeem(100e6, bob, bob);
        assertApproxEqAbs(asset.balanceOf(bob), 50e6, 3, "!balance");
    }

    function test_startCooldown_reverts() public {
        mintAndDepositIntoStrategy(trancheB, alice, 100e6);

        vm.startPrank(alice);

        vm.expectRevert("!shares");
        trancheB.startCooldown(0);

        vm.expectRevert("!shares");
        trancheB.startCooldown(uint256(type(uint128).max) + 1);

        vm.expectRevert("!balance");
        trancheB.startCooldown(100e6 + 1);

        vm.expectRevert("!pending");
        trancheB.cancelCooldown();

        vm.stopPrank();
    }

    function test_noCooldownOnTheSenior() public {
        mintAndDepositIntoStrategy(trancheA, alice, 100e6);

        vm.prank(alice);
        vm.expectRevert("!cooldown");
        trancheA.startCooldown(100e6);

        // In and out in the same block
        assertEq(trancheA.maxRedeem(alice), 100e6, "!maxRedeem");
        vm.prank(alice);
        trancheA.redeem(100e6, alice, alice);
        assertEq(asset.balanceOf(alice), 100e6, "!balance");
    }

    function test_shutdownLiftsTheCooldown() public {
        mintAndDepositIntoStrategy(trancheB, alice, 200e6);

        vm.prank(alice);
        trancheB.startCooldown(100e6);

        vm.prank(emergencyAdmin);
        trancheB.shutdownStrategy();

        // Everything can leave or move right away
        assertEq(trancheB.maxRedeem(alice), 200e6, "!maxRedeem");
        vm.prank(alice);
        trancheB.transfer(bob, 150e6);
        vm.prank(alice);
        trancheB.redeem(50e6, alice, alice);
        assertEq(asset.balanceOf(alice), 50e6, "!balance");
    }

}
