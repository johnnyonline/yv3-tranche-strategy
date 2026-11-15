// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface, Roles, MockStrategy} from "./utils/Setup.sol";

contract OperationTest is Setup {

    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategyOK() public {
        console2.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(address(strategy), address(trancheA));

        _checkTranche(trancheA, "Tranche A", "yvUSD-A", address(0), address(trancheB), PREMIUM_A, 0);
        _checkTranche(trancheB, "Tranche B", "yvUSD-B", address(trancheA), address(trancheE), PREMIUM_B, 14 days);
        _checkTranche(trancheE, "Tranche E", "yvUSD-E", address(trancheB), address(0), 0, 30 days);
    }

    function test_setupVaultOK() public {
        // A fresh vault, on the version yvUSD runs and with its unlock time
        assertTrue(address(vault) != address(YVUSD));
        assertEq(vault.apiVersion(), YVUSD.apiVersion());
        assertEq(vault.asset(), YVUSD.asset());
        assertEq(vault.profitMaxUnlockTime(), YVUSD.profitMaxUnlockTime());
        assertEq(vault.deposit_limit(), type(uint256).max);
        assertTrue(vault.auto_allocate());
        assertEq(vault.role_manager(), management);
        assertEq(vault.roles(keeper), Roles.REPORTING_MANAGER);
        address[] memory _queue = vault.get_default_queue();
        assertEq(_queue.length, 1);
        assertEq(_queue[0], address(vaultStrategy));
    }

    function test_operation(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");
        assertEq(strategy.balanceOfAsset(), 0, "!idle");
        assertEq(strategy.valueOfVault(), _amount, "!valueOfVault");
        assertEq(vault.totalAssets(), _amount, "!vault");
        checkStrategyTotals(strategy, _amount, _amount, 0);

        // Earn Interest
        skip(1 days);

        // Report profit
        vm.prank(management);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertEq(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertEq(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
        checkStrategyTotals(strategy, 0, 0, 0);
    }

    function test_profitableReport(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // The vault earns, books it and unlocks it
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        earn(toAirdrop);
        report();
        skip(vault.profitMaxUnlockTime());

        // Report profit
        vm.prank(management);
        (uint256 profit, uint256 loss) = strategy.report();

        // The tranche is the vault's only depositor, and keeps what it earned less the premium it passes down
        uint256 premium = toAirdrop * PREMIUM_A / MAX_BPS;
        assertApproxEqAbs(profit, toAirdrop - premium, 3, "!profit");
        assertEq(loss, 0, "!loss");
        assertApproxEqAbs(trancheB.valueOfVault(), premium, 3, "!premium");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertEq(asset.balanceOf(user), balanceBefore + _amount + profit, "!final balance");
    }

    function test_profitableReport_withFees(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Set protocol fee to 0 and perf fee to 10%
        setFees(0, 1_000);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // The vault earns, books it and unlocks it
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        earn(toAirdrop);
        report();
        skip(vault.profitMaxUnlockTime());

        // Report profit
        vm.prank(management);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertApproxEqAbs(profit, toAirdrop - toAirdrop * PREMIUM_A / MAX_BPS, 3, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        // Get the expected fee
        uint256 expectedShares = (profit * 1_000) / MAX_BPS;

        assertEq(strategy.balanceOf(performanceFeeRecipient), expectedShares);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        // The vault has earned nothing since, so the last one out is short of what rounding its shares cost
        uint256 feeShares = strategy.maxRedeem(performanceFeeRecipient);
        assertApproxEqAbs(feeShares, expectedShares, 3, "!maxRedeem");

        vm.prank(performanceFeeRecipient);
        strategy.redeem(feeShares, performanceFeeRecipient, performanceFeeRecipient);

        assertLe(strategy.totalAssets(), 3, "!totalAssets");

        assertGe(asset.balanceOf(performanceFeeRecipient) + 3, expectedShares, "!perf fee out");
    }

    function test_depositLimit_followsTheVaultAndTheGate() public {
        assertEq(strategy.maxDeposit(user), type(uint256).max, "!open");

        // The vault only takes another 100
        vm.prank(management);
        vault.set_deposit_limit(100e6);
        assertEq(strategy.maxDeposit(user), 100e6, "!vault limit");

        airdrop(asset, user, 101e6);
        vm.startPrank(user);
        asset.approve(address(strategy), 101e6);
        vm.expectRevert("ERC4626: deposit more than max");
        strategy.deposit(101e6, user);
        strategy.deposit(100e6, user);
        vm.stopPrank();
        assertEq(strategy.maxDeposit(user), 0, "!full");

        // A closed tranche only takes the depositors it allows
        vm.startPrank(management);
        vault.set_deposit_limit(type(uint256).max);
        strategy.setOpen(false);
        assertEq(strategy.maxDeposit(user), 0, "!closed");
        strategy.setAllowed(user, true);
        assertGt(strategy.maxDeposit(user), 0, "!allowed");
        vm.stopPrank();
    }

    function test_withdrawLimit_followsTheVault() public {
        mintAndDepositIntoStrategy(strategy, user, 100e6);
        assertEq(strategy.maxWithdraw(user), 100e6, "!liquid");

        // The vault can only get 40 out of its strategy
        MockStrategy(address(vaultStrategy)).setWithdrawLimit(40e6);
        assertEq(strategy.maxWithdraw(user), 40e6, "!maxWithdraw");
        assertEq(strategy.maxRedeem(user), 40e6, "!maxRedeem");

        // Asking for more reverts, it is not paid short as a loss
        vm.startPrank(user);
        vm.expectRevert("ERC4626: redeem more than max");
        strategy.redeem(40e6 + 1, user, user);
        uint256 balanceBefore = asset.balanceOf(user);
        strategy.redeem(40e6, user, user);
        vm.stopPrank();

        assertEq(asset.balanceOf(user), balanceBefore + 40e6, "!balance");
        assertEq(strategy.totalAssets(), 60e6, "!totalAssets");
    }

    function test_tendTrigger(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        (bool trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Skip some time
        skip(1 days);

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        report();

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Unlock Profits
        skip(strategy.profitMaxUnlockTime());

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);
    }

    function _checkTranche(
        IStrategyInterface _tranche,
        string memory _name,
        string memory _symbol,
        address _senior,
        address _junior,
        uint256 _premium,
        uint256 _cooldownDuration
    ) internal {
        assertEq(_tranche.asset(), address(asset));
        assertEq(_tranche.name(), _name);
        assertEq(_tranche.symbol(), _symbol);
        assertEq(_tranche.management(), management);
        assertEq(_tranche.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(_tranche.keeper(), keeper);
        assertEq(_tranche.emergencyAdmin(), emergencyAdmin);
        assertEq(_tranche.performanceFee(), 0);
        assertEq(_tranche.profitMaxUnlockTime(), 2 days);
        assertTrue(_tranche.doHealthCheck());
        assertEq(_tranche.profitLimitRatio(), 10_000);
        assertEq(_tranche.lossLimitRatio(), 0);
        assertTrue(_tranche.open());
        assertEq(_tranche.VAULT(), address(vault));
        assertEq(_tranche.SENIOR(), _senior);
        assertEq(_tranche.junior(), _junior);
        assertEq(_tranche.premium(), _premium);
        assertEq(_tranche.cooldownDuration(), _cooldownDuration);
        assertEq(strategyFactory.deployments(address(vault), _senior), address(_tranche));
        assertEq(asset.allowance(address(_tranche), address(vault)), type(uint256).max);
    }

}
