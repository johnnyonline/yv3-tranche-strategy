// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";

contract WaterfallTest is Setup {

    address public alice;
    address public bob;
    address public carol;

    // What each tranche starts with, 1M in total
    uint256 public constant DEPOSIT_A = 800_000e6;
    uint256 public constant DEPOSIT_B = 100_000e6;
    uint256 public constant DEPOSIT_E = 100_000e6;

    function setUp() public virtual override {
        super.setUp();

        // Fresh addresses, the low ones hold USDC on mainnet
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        mintAndDepositIntoStrategy(trancheA, alice, DEPOSIT_A);
        mintAndDepositIntoStrategy(trancheB, bob, DEPOSIT_B);
        mintAndDepositIntoStrategy(trancheE, carol, DEPOSIT_E);

        skip(1 days);
    }

    // ===============================================================
    // Profit
    // ===============================================================

    function test_profit_premiumIsPassedDown() public {
        // The vault earns 10%
        earnAndReport(100_000e6);

        // A keeps 80% of its 80k. B earns 10k plus A's 16k and keeps half. E earns 10k plus B's 13k
        assertApproxEqAbs(trancheA.totalAssets(), 864_000e6, 5, "!A");
        assertApproxEqAbs(trancheB.totalAssets(), 113_000e6, 5, "!B");
        assertApproxEqAbs(trancheE.totalAssets(), 123_000e6, 5, "!E");

        // Each tranche holds what it accounts for, and nothing was created or lost on the way down
        assertEq(held(trancheA), trancheA.totalAssets(), "!held A");
        assertEq(held(trancheB), trancheB.totalAssets(), "!held B");
        assertEq(held(trancheE), trancheE.totalAssets(), "!held E");
        assertApproxEqAbs(held(trancheA) + held(trancheB) + held(trancheE), vault.totalAssets(), 5, "!conserved");
        assertEq(vault.totalAssets(), 1_100_000e6, "!vault");

        // The profit is locked, then shows up in the price
        assertApproxEqAbs(trancheA.pricePerShare(), 1e6, 1, "!locked A");
        assertApproxEqAbs(trancheE.pricePerShare(), 1e6, 1, "!locked E");
        skip(trancheA.profitMaxUnlockTime());
        assertApproxEqAbs(trancheA.pricePerShare(), 1.08e6, 1, "!pps A");
        assertApproxEqAbs(trancheB.pricePerShare(), 1.13e6, 1, "!pps B");
        assertApproxEqAbs(trancheE.pricePerShare(), 1.23e6, 1, "!pps E");
    }

    function test_profit_mostJuniorKeepsItAll() public {
        vm.prank(management);
        trancheB.setJunior(address(0));

        earnAndReport(100_000e6);

        // B is now the bottom of the stack and passes nothing down
        assertApproxEqAbs(trancheA.totalAssets(), 864_000e6, 5, "!A");
        assertApproxEqAbs(trancheB.totalAssets(), 126_000e6, 5, "!B");

        // E is on its own, and just earns its own 10k
        assertEq(trancheE.totalAssets(), DEPOSIT_E, "!E before report");
        vm.prank(keeper);
        trancheE.report();
        assertApproxEqAbs(trancheE.totalAssets(), 110_000e6, 5, "!E");
    }

    function test_profit_netOfASmallerLoss() public {
        // The vault earns 10% and unlocks it, which the tranches have not reported yet
        earn(100_000e6);
        report();
        skip(vault.profitMaxUnlockTime());

        // Then it loses 50k
        lose(50_000e6);
        report();

        // Nobody is short, so no cover moves and the premium is paid on the 5% that is left
        assertApproxEqAbs(trancheA.totalAssets(), 832_000e6, 5, "!A");
        assertApproxEqAbs(trancheB.totalAssets(), 106_500e6, 5, "!B");
        assertApproxEqAbs(trancheE.totalAssets(), 111_500e6, 5, "!E");
    }

    // ===============================================================
    // Loss
    // ===============================================================

    function test_loss_mostJuniorPaysFirst() public {
        // The vault loses 5%. Management lets E report it
        lose(50_000e6);
        allowLoss(trancheE);
        report();

        // E takes all of it: its own 5k, B's 5k and A's 40k
        assertApproxEqAbs(trancheA.totalAssets(), DEPOSIT_A, 3, "!A");
        assertApproxEqAbs(trancheB.totalAssets(), DEPOSIT_B, 3, "!B");
        assertApproxEqAbs(trancheE.totalAssets(), DEPOSIT_E - 50_000e6, 6, "!E");

        // In the same call, so no price is left stale
        assertApproxEqAbs(trancheA.pricePerShare(), 1e6, 1, "!pps A");
        assertApproxEqAbs(trancheB.pricePerShare(), 1e6, 1, "!pps B");
        assertApproxEqAbs(trancheE.pricePerShare(), 0.5e6, 1, "!pps E");

        // Each tranche holds what it accounts for
        assertEq(held(trancheA), trancheA.totalAssets(), "!held A");
        assertEq(held(trancheB), trancheB.totalAssets(), "!held B");
        assertEq(held(trancheE), trancheE.totalAssets(), "!held E");
        assertEq(vault.totalAssets(), 950_000e6, "!vault");
    }

    function test_loss_nextJuniorPaysTheRest() public {
        // The vault loses 15%, more than E has
        lose(150_000e6);
        allowLoss(trancheB);
        allowLoss(trancheE);
        report();

        // E is emptied and B takes the other 50k
        assertApproxEqAbs(trancheA.totalAssets(), DEPOSIT_A, 3, "!A");
        assertApproxEqAbs(trancheB.totalAssets(), DEPOSIT_B - 50_000e6, 6, "!B");
        assertApproxEqAbs(trancheE.totalAssets(), 0, 3, "!E");
        assertApproxEqAbs(trancheE.valueOfVault(), 0, 3, "!held E");
    }

    function test_loss_seniorTakesOnlyWhatIsLeft() public {
        // The vault loses 30%, more than B and E have together
        lose(300_000e6);
        allowLoss(trancheA);
        allowLoss(trancheB);
        allowLoss(trancheE);
        report();

        // B and E are emptied and A takes the other 100k
        assertApproxEqAbs(trancheA.totalAssets(), DEPOSIT_A - 100_000e6, 6, "!A");
        assertApproxEqAbs(trancheB.totalAssets(), 0, 3, "!B");
        assertApproxEqAbs(trancheE.totalAssets(), 0, 3, "!E");
        assertApproxEqAbs(trancheA.pricePerShare(), 0.875e6, 1, "!pps A");
        assertEq(held(trancheA), trancheA.totalAssets(), "!held A");
    }

    function test_loss_followsTheWaterfall(
        uint256 _a,
        uint256 _b,
        uint256 _e,
        uint256 _lossBps
    ) public {
        _a = bound(_a, minFuzzAmount, maxFuzzAmount);
        _b = bound(_b, minFuzzAmount, maxFuzzAmount);
        _e = bound(_e, minFuzzAmount, maxFuzzAmount);
        _lossBps = bound(_lossBps, 1, MAX_BPS - 1);

        mintAndDepositIntoStrategy(trancheA, alice, _a);
        mintAndDepositIntoStrategy(trancheB, bob, _b);
        mintAndDepositIntoStrategy(trancheE, carol, _e);
        _a += DEPOSIT_A;
        _b += DEPOSIT_B;
        _e += DEPOSIT_E;

        skip(1 days);
        uint256 _total = _a + _b + _e;
        lose(_total * _lossBps / MAX_BPS);
        allowLoss(trancheA);
        allowLoss(trancheB);
        allowLoss(trancheE);
        report();

        // What is left goes to A first, then to B, then to E
        uint256 _left = _total - _total * _lossBps / MAX_BPS;
        uint256 _expectedA = _left < _a ? _left : _a;
        uint256 _expectedB = _left - _expectedA < _b ? _left - _expectedA : _b;
        uint256 _expectedE = _left - _expectedA - _expectedB;
        assertApproxEqAbs(trancheA.totalAssets(), _expectedA, 10, "!A");
        assertApproxEqAbs(trancheB.totalAssets(), _expectedB, 10, "!B");
        assertApproxEqAbs(trancheE.totalAssets(), _expectedE, 10, "!E");

        assertEq(held(trancheA), trancheA.totalAssets(), "!held A");
        assertEq(held(trancheB), trancheB.totalAssets(), "!held B");
        assertEq(held(trancheE), trancheE.totalAssets(), "!held E");
    }

    function test_loss_coverIsPulledBeforeAWithdrawal() public {
        // The vault books a 5% loss. No tranche has reported it yet
        lose(50_000e6);
        reportVault();

        // A still accounts for all of it but holds 40k less
        assertEq(trancheA.totalAssets(), DEPOSIT_A, "!totalAssets");
        assertApproxEqAbs(held(trancheA), DEPOSIT_A - 40_000e6, 2, "!held");

        // Alice can take out what A holds. Her withdrawal pulls the cover first, so she is paid in full
        uint256 _shares = trancheA.maxRedeem(alice);
        assertApproxEqAbs(_shares, DEPOSIT_A - 40_000e6, 2, "!maxRedeem");
        vm.prank(alice);
        trancheA.redeem(_shares, alice, alice);
        assertEq(asset.balanceOf(alice), _shares, "!first withdrawal");

        // Then the rest, out of what the tranches below paid
        _shares = trancheA.balanceOf(alice);
        assertApproxEqAbs(trancheA.maxRedeem(alice), _shares, 2, "!maxRedeem after cover");
        vm.prank(alice);
        trancheA.redeem(_shares, alice, alice);
        assertApproxEqAbs(asset.balanceOf(alice), DEPOSIT_A, 2, "!paid in full");

        // E paid for A through B, and pays for B at the next report
        assertApproxEqAbs(held(trancheB), DEPOSIT_B - 5_000e6, 3, "!held B");
        assertApproxEqAbs(held(trancheE), DEPOSIT_E - 45_000e6, 3, "!held E");
        mintAndDepositIntoStrategy(trancheA, user, 1e6); // An empty tranche cannot report the dust it is left with
        allowLoss(trancheE);
        report();
        assertApproxEqAbs(trancheB.totalAssets(), DEPOSIT_B, 3, "!B");
        assertApproxEqAbs(trancheE.totalAssets(), DEPOSIT_E - 50_000e6, 6, "!E");
    }

    function test_loss_unlinkedSeniorIsNotCovered() public {
        vm.prank(management);
        trancheA.setJunior(address(0));

        lose(50_000e6);
        allowLoss(trancheA);
        report();

        // A takes its own 40k
        assertApproxEqAbs(trancheA.totalAssets(), DEPOSIT_A - 40_000e6, 3, "!A");

        // B and E are on their own. E still covers B
        allowLoss(trancheE);
        vm.startPrank(keeper);
        trancheB.report();
        trancheE.report();
        vm.stopPrank();
        assertApproxEqAbs(trancheB.totalAssets(), DEPOSIT_B, 3, "!B");
        assertApproxEqAbs(trancheE.totalAssets(), DEPOSIT_E - 10_000e6, 6, "!E");
    }

    function test_loss_recoveryIsSharedLikeAnyProfit() public {
        // The vault loses 5%, which E covers, then earns the 50k back
        lose(50_000e6);
        allowLoss(trancheE);
        report();
        earnAndReport(50_000e6);

        // It is profit like any other, split by what each tranche holds. E only sees A's and B's shares of it
        // through the premiums, and is not made whole
        assertApproxEqAbs(trancheA.totalAssets(), 833_684_210_526, 10, "!A");
        assertApproxEqAbs(trancheB.totalAssets(), 106_842_105_263, 10, "!B");
        assertApproxEqAbs(trancheE.totalAssets(), 59_473_684_209, 10, "!E");
        assertEq(vault.totalAssets(), 1_000_000e6, "!vault");
    }

    // ===============================================================
    // Adding a tranche
    // ===============================================================

    function test_addJuniorAfterLaunch() public {
        // Deploy a tranche below E and link it
        IStrategyInterface trancheF = _newTranche(address(trancheE));

        vm.prank(management);
        trancheE.setJunior(address(trancheF));

        mintAndDepositIntoStrategy(trancheF, user, 100_000e6);
        skip(1 days);

        // It takes the whole of the next loss
        lose(50_000e6);
        allowLoss(trancheF);
        report();
        assertEq(trancheF.lastReport(), block.timestamp, "!reported");
        assertApproxEqAbs(trancheA.totalAssets(), DEPOSIT_A, 3, "!A");
        assertApproxEqAbs(trancheB.totalAssets(), DEPOSIT_B, 3, "!B");
        assertApproxEqAbs(trancheE.totalAssets(), DEPOSIT_E, 3, "!E");
        assertApproxEqAbs(trancheF.totalAssets(), 50_000e6, 8, "!F");
    }

    function test_emptiedJuniorCanBeReplaced() public {
        // The vault loses 15%: E is emptied and B is left with 50k
        lose(150_000e6);
        allowLoss(trancheB);
        allowLoss(trancheE);
        report();

        // Deploy a new tranche below B and link it in E's place
        IStrategyInterface trancheF = _newTranche(address(trancheB));

        vm.prank(management);
        trancheB.setJunior(address(trancheF));

        mintAndDepositIntoStrategy(trancheF, user, 100_000e6);
        skip(1 days);

        // The vault loses another 2%, 19k, and the new tranche takes all of it
        lose(19_000e6);
        allowLoss(trancheF);
        report();
        assertApproxEqAbs(trancheA.totalAssets(), DEPOSIT_A, 3, "!A");
        assertApproxEqAbs(trancheB.totalAssets(), DEPOSIT_B - 50_000e6, 6, "!B");
        assertApproxEqAbs(trancheF.totalAssets(), 81_000e6, 8, "!F");
    }

    // The factory's management deploys a tranche below `_senior`, sets it up and hands it over
    function _newTranche(
        address _senior
    ) internal returns (IStrategyInterface _tranche) {
        vm.startPrank(vm.addr(42069));
        _tranche = IStrategyInterface(
            strategyFactory.newStrategy(address(asset), "Tranche F", "yvUSD-F", address(vault), _senior)
        );
        _tranche.acceptManagement();
        _tranche.setPerformanceFee(0);
        _tranche.setOpen(true);
        _tranche.setPendingManagement(management);
        vm.stopPrank();

        vm.prank(management);
        _tranche.acceptManagement();
    }

    // ===============================================================
    // Donations
    // ===============================================================

    function test_donation_doesNotMoveThePrice() public {
        uint256 _pps = trancheA.pricePerShare();
        uint256 _totalAssets = trancheA.totalAssets();
        uint256 _maxWithdraw = trancheA.maxWithdraw(alice);

        // Donate `asset` and vault shares to A
        airdrop(asset, address(trancheA), 100_000e6);
        airdrop(asset, user, 100_000e6);
        vm.startPrank(user);
        asset.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, address(trancheA));
        vm.stopPrank();

        skip(1 days);
        assertEq(trancheA.pricePerShare(), _pps, "!pps");
        assertEq(trancheA.totalAssets(), _totalAssets, "!totalAssets");
        assertEq(trancheA.maxWithdraw(alice), _maxWithdraw, "!maxWithdraw");

        // The next deposit puts the idle `asset` into the vault, still without moving the price
        mintAndDepositIntoStrategy(trancheA, user, 1e6);
        assertEq(trancheA.balanceOfAsset(), 0, "!idle");
        assertEq(trancheA.pricePerShare(), _pps, "!pps after deposit");

        // The report books it as profit, less the premium, and locks it
        report();
        assertApproxEqAbs(trancheA.totalAssets(), _totalAssets + 1e6 + 160_000e6, 5, "!profit");
        assertApproxEqAbs(trancheA.pricePerShare(), _pps, 1, "!pps after report");
        skip(trancheA.profitMaxUnlockTime());
        assertGt(trancheA.pricePerShare(), _pps, "!pps unlocked");
    }

}
