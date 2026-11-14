// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";

// Every tranche keeps the stock health check: a gain of at most 100% per report, and no loss at all
contract HealthCheckTest is Setup {

    address public alice;
    address public bob;
    address public carol;

    // What each tranche starts with, 1M in total
    uint256 public constant DEPOSIT_A = 800_000e6;
    uint256 public constant DEPOSIT_B = 100_000e6;
    uint256 public constant DEPOSIT_E = 100_000e6;

    function setUp() public virtual override {
        super.setUp();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        mintAndDepositIntoStrategy(trancheA, alice, DEPOSIT_A);
        mintAndDepositIntoStrategy(trancheB, bob, DEPOSIT_B);
        mintAndDepositIntoStrategy(trancheE, carol, DEPOSIT_E);

        skip(1 days);
    }

    function test_setupHealthCheckOK() public {
        assertTrue(trancheE.doHealthCheck(), "!doHealthCheck");
        assertEq(trancheE.profitLimitRatio(), 10_000, "!profitLimitRatio");
        assertEq(trancheE.lossLimitRatio(), 0, "!lossLimitRatio");
    }

    // ===============================================================
    // Loss
    // ===============================================================

    function test_loss_needsManagement() public {
        // The vault's strategy loses 5%, and the vault books it
        lose(50_000e6);
        reportVault();
        assertEq(vault.totalAssets(), 950_000e6, "!vault");

        // The keeper reports A and B, which the junior tranches top up
        vm.startPrank(keeper);
        trancheA.report();
        trancheB.report();

        // But not E, which is the one taking the loss
        vm.expectRevert("healthCheck");
        trancheE.report();
        vm.stopPrank();

        assertApproxEqAbs(trancheA.totalAssets(), DEPOSIT_A, 3, "!A");
        assertApproxEqAbs(trancheB.totalAssets(), DEPOSIT_B, 3, "!B");
        assertEq(trancheE.totalAssets(), DEPOSIT_E, "!E before");
        assertApproxEqAbs(held(trancheE), DEPOSIT_E - 50_000e6, 6, "!held E");

        // Management switches its check off and reports it
        vm.startPrank(management);
        trancheE.setDoHealthCheck(false);
        trancheE.report();
        vm.stopPrank();

        assertApproxEqAbs(trancheE.totalAssets(), DEPOSIT_E - 50_000e6, 6, "!E");

        // The check is back on for the next report
        assertTrue(trancheE.doHealthCheck(), "!doHealthCheck");
    }

    function test_loss_everyTrancheThatTakesItNeedsManagement() public {
        // The vault's strategy loses 15%, more than E has, so B takes a loss too
        lose(150_000e6);
        reportVault();

        vm.startPrank(keeper);
        trancheA.report();
        vm.expectRevert("healthCheck");
        trancheB.report();
        vm.expectRevert("healthCheck");
        trancheE.report();
        vm.stopPrank();

        vm.startPrank(management);
        trancheB.setDoHealthCheck(false);
        trancheB.report();
        trancheE.setDoHealthCheck(false);
        trancheE.report();
        vm.stopPrank();

        assertApproxEqAbs(trancheA.totalAssets(), DEPOSIT_A, 3, "!A");
        assertApproxEqAbs(trancheB.totalAssets(), DEPOSIT_B - 50_000e6, 6, "!B");
        assertApproxEqAbs(trancheE.totalAssets(), 0, 3, "!E");
    }

    function test_loss_howeverSmallNeedsManagement() public {
        // The vault's strategy loses a single dollar out of 1M
        lose(1e6);
        reportVault();

        vm.startPrank(keeper);
        trancheA.report();
        trancheB.report();
        vm.expectRevert("healthCheck");
        trancheE.report();
        vm.stopPrank();

        allowLoss(trancheE);
        vm.prank(keeper);
        trancheE.report();

        assertApproxEqAbs(trancheA.totalAssets(), DEPOSIT_A, 3, "!A");
        assertApproxEqAbs(trancheB.totalAssets(), DEPOSIT_B, 3, "!B");
        assertApproxEqAbs(trancheE.totalAssets(), DEPOSIT_E - 1e6, 6, "!E");
    }

    function test_loss_roundingCanLeaveTheBottomTrancheShort() public {
        // The vault's price moves away from 1, so deposits no longer convert to whole vault shares
        earnAndReport(100_000e6);

        // E has nobody below it to top it up. With the vault earning nothing in between, a few deposits leave it
        // a wei or two short of what it accounts for
        for (uint256 i = 0; i < 5; i++) {
            mintAndDepositIntoStrategy(trancheE, carol, 1_000_001 + 2 * i);
        }
        uint256 _totalAssets = trancheE.totalAssets();
        uint256 _short = _totalAssets - held(trancheE);
        assertGt(_short, 0, "!short");
        assertLe(_short, 10, "!dust");

        // That counts as a loss, so E cannot be reported
        vm.prank(keeper);
        vm.expectRevert("healthCheck");
        trancheE.report();

        // Until the vault's price next moves up
        earn(1_000e6);
        reportVault();
        skip(1 hours);
        vm.prank(keeper);
        trancheE.report();
        assertGt(trancheE.totalAssets(), _totalAssets, "!E");
        assertEq(trancheE.totalAssets(), held(trancheE), "!held E");
    }

    // ===============================================================
    // Gain
    // ===============================================================

    function test_gain_tooHighForATinyJunior() public {
        // Carol leaves E, and someone else puts a single dollar in
        vm.prank(carol);
        trancheE.startCooldown(DEPOSIT_E);
        skip(30 days);
        vm.prank(carol);
        trancheE.redeem(DEPOSIT_E, carol, carol);
        mintAndDepositIntoStrategy(trancheE, user, 1e6);

        // The vault earns 10%
        earn(90_000.1e6);
        report();
        skip(vault.profitMaxUnlockTime());

        // A and B report it and pass their premiums down. B's 13k is thousands of times what E holds
        vm.startPrank(keeper);
        trancheA.report();
        trancheB.report();
        vm.expectRevert("healthCheck");
        trancheE.report();
        vm.stopPrank();

        // B has paid it all the same. It waits in E until E can report it
        assertApproxEqAbs(trancheA.totalAssets(), 864_000e6, 5, "!A");
        assertApproxEqAbs(trancheB.totalAssets(), 113_000e6, 5, "!B");
        assertEq(trancheE.totalAssets(), 1e6, "!E");
        assertApproxEqAbs(held(trancheE), 13_001.1e6, 5, "!held E");
    }

    function test_gain_premiumToAnEmptyJuniorGoesToItsNextDepositor() public {
        // Carol leaves E empty
        vm.prank(carol);
        trancheE.startCooldown(DEPOSIT_E);
        skip(30 days);
        vm.prank(carol);
        trancheE.redeem(DEPOSIT_E, carol, carol);
        assertEq(trancheE.totalSupply(), 0, "!empty");

        // The vault earns 10%. A and B report it, and B passes 13k down to E
        earn(90_000e6);
        report();
        skip(vault.profitMaxUnlockTime());
        vm.startPrank(keeper);
        trancheA.report();
        trancheB.report();

        // Which E cannot report, as a gain on nothing
        vm.expectRevert("healthCheck");
        trancheE.report();
        vm.stopPrank();
        assertApproxEqAbs(held(trancheE), 13_000e6, 5, "!held E");

        // Until someone deposits enough for it to be under the limit, and collects it
        mintAndDepositIntoStrategy(trancheE, alice, 20_000e6);
        vm.prank(keeper);
        trancheE.report();
        skip(trancheE.profitMaxUnlockTime());
        assertApproxEqAbs(trancheE.convertToAssets(trancheE.balanceOf(alice)), 33_000e6, 5, "!alice");
    }

    function test_gain_donationTooHigh() public {
        // Someone sends E more vault shares than it holds
        airdrop(asset, user, 150_000e6);
        vm.startPrank(user);
        asset.approve(address(vault), 150_000e6);
        vault.deposit(150_000e6, address(trancheE));
        vm.stopPrank();

        vm.prank(keeper);
        vm.expectRevert("healthCheck");
        trancheE.report();

        // Management lets it through as profit, which is locked like any other
        vm.startPrank(management);
        trancheE.setDoHealthCheck(false);
        trancheE.report();
        vm.stopPrank();
        assertApproxEqAbs(trancheE.totalAssets(), DEPOSIT_E + 150_000e6, 5, "!E");
        assertApproxEqAbs(trancheE.pricePerShare(), 1e6, 1, "!pps");
    }

    function test_gain_limitIsOnWhatATrancheKeeps() public {
        // Someone sends B one and a half times what it holds
        airdrop(asset, user, 150_000e6);
        vm.startPrank(user);
        asset.approve(address(vault), 150_000e6);
        vault.deposit(150_000e6, address(trancheB));
        vm.stopPrank();

        // B passes half of it down, so both B and E end up 75% higher, under the limit
        report();
        assertApproxEqAbs(trancheB.totalAssets(), DEPOSIT_B + 75_000e6, 5, "!B");
        assertApproxEqAbs(trancheE.totalAssets(), DEPOSIT_E + 75_000e6, 5, "!E");
    }

}
