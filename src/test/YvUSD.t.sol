// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";

// The other tests run on a fresh vault they can make earn and lose. These run on yvUSD itself, as deployed
contract YvUSDTest is Setup {

    address public alice;
    address public bob;
    address public carol;

    uint256 public constant DEPOSIT_A = 800_000e6;
    uint256 public constant DEPOSIT_B = 100_000e6;
    uint256 public constant DEPOSIT_E = 100_000e6;

    function setUp() public virtual override {
        super.setUp();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
    }

    function setUpVault() public virtual override returns (address) {
        return address(YVUSD);
    }

    function test_setupOK() public {
        assertEq(address(vault), address(YVUSD));
        assertEq(vault.apiVersion(), "3.0.4");
        assertEq(vault.symbol(), "yvUSD");
        assertEq(vault.asset(), address(asset));

        assertEq(trancheA.VAULT(), address(YVUSD));
        assertEq(trancheB.VAULT(), address(YVUSD));
        assertEq(trancheE.VAULT(), address(YVUSD));
        assertEq(trancheA.asset(), address(asset));
        assertEq(trancheA.symbol(), "yvUSD-A");
        assertEq(trancheB.symbol(), "yvUSD-B");
        assertEq(trancheE.symbol(), "yvUSD-E");

        // A tranche takes what the vault still has room for
        assertGt(trancheA.maxDeposit(alice), 0);
        assertEq(trancheA.maxDeposit(alice), vault.maxDeposit(address(trancheA)));
    }

    function test_operation() public {
        mintAndDepositIntoStrategy(trancheA, alice, DEPOSIT_A);
        mintAndDepositIntoStrategy(trancheB, bob, DEPOSIT_B);
        mintAndDepositIntoStrategy(trancheE, carol, DEPOSIT_E);

        assertApproxEqAbs(held(trancheA), DEPOSIT_A, 3, "!held A");
        assertApproxEqAbs(held(trancheB), DEPOSIT_B, 3, "!held B");
        assertApproxEqAbs(held(trancheE), DEPOSIT_E, 3, "!held E");
        assertApproxEqAbs(trancheA.maxWithdraw(alice), DEPOSIT_A, 3, "!maxWithdraw");

        // The vault's price moves up as the profit it has locked unlocks
        uint256 _pps = vault.pricePerShare();
        skip(3 days);
        assertGt(vault.pricePerShare(), _pps, "!pps");

        // The keeper reports the tranches, which pass their premiums down
        vm.startPrank(keeper);
        (uint256 _profitA, uint256 _lossA) = trancheA.report();
        (uint256 _profitB, uint256 _lossB) = trancheB.report();
        (uint256 _profitE, uint256 _lossE) = trancheE.report();
        vm.stopPrank();

        assertEq(_lossA + _lossB + _lossE, 0, "!loss");
        assertGt(_profitA, 0, "!profit");

        // Per dollar, E earned more than B, which earned more than A
        assertGt(_profitB * DEPOSIT_A, _profitA * DEPOSIT_B, "!B > A");
        assertGt(_profitE * DEPOSIT_B, _profitB * DEPOSIT_E, "!E > B");

        // A is out at once and in full
        vm.prank(alice);
        trancheA.redeem(DEPOSIT_A, alice, alice);
        assertGe(asset.balanceOf(alice), DEPOSIT_A, "!alice");

        // B after its cooldown
        vm.prank(bob);
        trancheB.startCooldown(DEPOSIT_B);
        skip(14 days);
        vm.prank(bob);
        trancheB.redeem(DEPOSIT_B, bob, bob);
        assertGe(asset.balanceOf(bob), DEPOSIT_B, "!bob");
    }

}
