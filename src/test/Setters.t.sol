// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface, IVault} from "./utils/Setup.sol";

contract SettersTest is Setup {

    function setUp() public virtual override {
        super.setUp();
    }

    function test_setJunior() public {
        vm.prank(user);
        vm.expectRevert("!management");
        trancheA.setJunior(address(0));

        // E was deployed below B, not below A
        vm.prank(management);
        vm.expectRevert("!junior");
        trancheA.setJunior(address(trancheE));

        // Nor can the stack be turned upside down
        vm.prank(management);
        vm.expectRevert("!junior");
        trancheE.setJunior(address(trancheA));

        // Unlink, then link again
        vm.startPrank(management);
        trancheA.setJunior(address(0));
        assertEq(trancheA.junior(), address(0), "!unlinked");
        trancheA.setJunior(address(trancheB));
        assertEq(trancheA.junior(), address(trancheB), "!linked");
        vm.stopPrank();
    }

    function test_setPremium(
        uint256 _premium
    ) public {
        vm.prank(user);
        vm.expectRevert("!management");
        trancheA.setPremium(_premium);

        vm.prank(management);
        if (_premium > MAX_BPS) vm.expectRevert("!premium");
        trancheA.setPremium(_premium);

        assertEq(trancheA.premium(), _premium > MAX_BPS ? PREMIUM_A : _premium, "!premium");
    }

    function test_setCooldown() public {
        assertEq(trancheB.MAX_COOLDOWN_DURATION(), 90 days, "!MAX_COOLDOWN_DURATION");
        assertEq(trancheB.MIN_WITHDRAWAL_WINDOW(), 7 days, "!MIN_WITHDRAWAL_WINDOW");

        vm.prank(user);
        vm.expectRevert("!management");
        trancheB.setCooldown(7 days, 7 days);

        vm.startPrank(management);

        vm.expectRevert("!duration");
        trancheB.setCooldown(90 days + 1, 7 days);

        vm.expectRevert("!window");
        trancheB.setCooldown(7 days, 7 days - 1);

        trancheB.setCooldown(90 days, 10 days);
        assertEq(trancheB.cooldownDuration(), 90 days, "!duration");
        assertEq(trancheB.withdrawalWindow(), 10 days, "!window");

        // No cooldown at all
        trancheB.setCooldown(0, 7 days);
        assertEq(trancheB.cooldownDuration(), 0, "!off");

        vm.stopPrank();
    }

    function test_cover_onlyTheTrancheAbove() public {
        mintAndDepositIntoStrategy(trancheB, user, 100e6);
        mintAndDepositIntoStrategy(trancheE, user, 100e6);

        vm.prank(user);
        vm.expectRevert("!senior");
        trancheB.cover(1e6);

        vm.prank(management);
        vm.expectRevert("!senior");
        trancheB.cover(1e6);

        // Not the tranche below, and not the one two above
        vm.prank(address(trancheE));
        vm.expectRevert("!senior");
        trancheB.cover(1e6);

        vm.prank(address(trancheA));
        vm.expectRevert("!senior");
        trancheE.cover(1e6);

        // B can ask E, and is paid in vault shares
        vm.prank(address(trancheB));
        trancheE.cover(1e6);
        assertEq(trancheB.balanceOfVault(), 101e6, "!B");
        assertEq(trancheE.balanceOfVault(), 99e6, "!E");
    }

    function test_newStrategy() public {
        address _deployer = vm.addr(42069);

        vm.prank(user);
        vm.expectRevert("!management");
        strategyFactory.newStrategy(address(asset), "Tranche F", "yvUSD-F", address(vault), address(trancheE));

        vm.startPrank(_deployer);

        // The vault holds another asset
        vm.expectRevert("!vault");
        strategyFactory.newStrategy(tokenAddrs["DAI"], "Tranche F", "yvUSD-F", address(vault), address(trancheE));

        // The tranche above is invested in another vault
        address _vault = VAULT_FACTORY.deploy_new_vault(address(asset), "Other", "OTHER", _deployer, 2 days);
        vm.expectRevert("!senior");
        strategyFactory.newStrategy(address(asset), "Tranche F", "yvUSD-F", _vault, address(trancheE));

        IStrategyInterface trancheF = IStrategyInterface(
            strategyFactory.newStrategy(address(asset), "Tranche F", "yvUSD-F", address(vault), address(trancheE))
        );

        vm.stopPrank();

        assertEq(trancheF.SENIOR(), address(trancheE), "!senior");
        assertEq(trancheF.VAULT(), address(vault), "!vault");
        assertEq(trancheF.junior(), address(0), "!junior");
        assertEq(trancheF.symbol(), "yvUSD-F", "!symbol");
        assertEq(trancheF.pendingManagement(), _deployer, "!pendingManagement");
        assertEq(trancheF.keeper(), keeper, "!keeper");
        assertEq(trancheF.emergencyAdmin(), emergencyAdmin, "!emergencyAdmin");
        assertEq(trancheF.performanceFeeRecipient(), performanceFeeRecipient, "!performanceFeeRecipient");
        assertEq(strategyFactory.deployments(address(vault), address(trancheE)), address(trancheF), "!deployments");
    }

}
