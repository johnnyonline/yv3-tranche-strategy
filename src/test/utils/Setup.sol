// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";
import "../../../script/Deploy.s.sol";

import {ERC20} from "../../Strategy.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {IVaultFactory} from "@yearn-vaults/interfaces/IVaultFactory.sol";
import {Roles} from "@yearn-vaults/interfaces/Roles.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";

// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";

interface IFactory {

    function governance() external view returns (address);

    function set_protocol_fee_bps(
        uint16
    ) external;

    function set_protocol_fee_recipient(
        address
    ) external;

}

contract Setup is Deploy, Test, IEvents {

    // Contract instances that we will use repeatedly.
    ERC20 public asset;
    IVault public vault;
    IStrategyInterface public strategy; // Most senior tranche
    IStrategyInterface public trancheA;
    IStrategyInterface public trancheB;
    IStrategyInterface public trancheE;
    IStrategy public vaultStrategy;
    StrategyFactory public strategyFactory;

    mapping(string => address) public tokenAddrs;

    // Addresses for different roles we will use repeatedly.
    address public user = address(10);
    address public keeper = address(4);
    address public management = address(1);
    address public performanceFeeRecipient = address(3);
    address public emergencyAdmin = address(5);
    address public sink = address(6);

    // Address of the real deployed Factory
    address public factory;

    // Factory yvUSD was deployed from, so the test vault runs the same version
    IVaultFactory public constant VAULT_FACTORY = IVaultFactory(0x770D0d1Fb036483Ed4AbB6d53c1C88fb277D812F); // 3.0.4 Vault Factory

    // Integer variables that will be used repeatedly.
    uint256 public decimals;
    uint256 public MAX_BPS = 10_000;

    // Fuzz from $1 up to $1B of USDC
    uint256 public maxFuzzAmount = 1_000_000_000e6;
    uint256 public minFuzzAmount = 1e6;

    function setUp() public virtual {
        uint256 _blockNumber = 26_410_000; // Caching for faster tests
        vm.selectFork(vm.createFork(vm.envString("ETH_RPC_URL"), _blockNumber));

        _setTokenAddrs();

        // Set asset
        asset = ERC20(tokenAddrs["USDC"]);

        // Set decimals
        decimals = asset.decimals();

        // Set script vars
        s_management = management;
        s_performanceFeeRecipient = performanceFeeRecipient;
        s_keeper = keeper;
        s_emergencyAdmin = emergencyAdmin;
        s_vault = IVault(setUpVault());

        // Deploy tranches and set variables
        strategy = IStrategyInterface(setUpStrategy());

        factory = strategy.FACTORY();
        strategyFactory = s_factory;
        vault = s_vault;
        trancheA = s_trancheA;
        trancheB = s_trancheB;
        trancheE = s_trancheE;

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(strategyFactory), "strategyFactory");
        vm.label(address(vault), "vault");
        vm.label(address(vaultStrategy), "vaultStrategy");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(trancheA), "trancheA");
        vm.label(address(trancheB), "trancheB");
        vm.label(address(trancheE), "trancheE");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public returns (address) {
        // notify deployment script that this is a test
        isTest = true;
        // deploy and initialize contracts
        run();

        vm.startPrank(management);
        s_trancheA.acceptManagement();
        s_trancheB.acceptManagement();
        s_trancheE.acceptManagement();
        vm.stopPrank();

        // the most senior tranche is the one users are expected to hold
        return address(s_trancheA);
    }

    // Tests run on a fresh vault set up like yvUSD, with a single strategy they can make earn and lose
    function setUpVault() public virtual returns (address) {
        // we are the strategy's management and keeper. It unlocks profit right away and charges no fees
        vaultStrategy = IStrategy(address(new MockStrategy(address(asset))));
        vaultStrategy.setProfitMaxUnlockTime(0);
        vaultStrategy.setPerformanceFee(0);

        vm.startPrank(management);
        IVault _vault =
            IVault(VAULT_FACTORY.deploy_new_vault(address(asset), "USD yVault", "yvUSD", management, 5 days));
        _vault.set_role(management, Roles.ALL);
        _vault.set_role(keeper, Roles.REPORTING_MANAGER);
        _vault.set_deposit_limit(type(uint256).max);
        _vault.set_auto_allocate(true);
        _vault.add_strategy(address(vaultStrategy));
        _vault.update_max_debt_for_strategy(address(vaultStrategy), type(uint256).max);
        vm.stopPrank();

        return address(_vault);
    }

    function depositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        airdrop(asset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    // The vault's strategy earns `_amount`
    function earn(
        uint256 _amount
    ) public {
        airdrop(asset, address(vaultStrategy), _amount);
        vaultStrategy.report();
    }

    // The vault's strategy loses `_amount`
    function lose(
        uint256 _amount
    ) public {
        vm.prank(address(vaultStrategy));
        asset.transfer(sink, _amount);
        vaultStrategy.report();
    }

    // The keeper bot reports the vault's strategy
    function reportVault() public {
        vm.prank(keeper);
        vault.process_report(address(vaultStrategy));
    }

    // The keeper bot reports every linked tranche, from the most senior down
    function reportTranches() public {
        IStrategyInterface _tranche = trancheA;
        while (address(_tranche) != address(0)) {
            vm.prank(keeper);
            _tranche.report();
            _tranche = IStrategyInterface(_tranche.junior());
        }
    }

    // The keeper bot reports the vault's strategy, then every linked tranche
    function report() public {
        reportVault();
        reportTranches();
    }

    // Management switches off the health check of a tranche for its next report, as it has to before a loss
    function allowLoss(
        IStrategyInterface _tranche
    ) public {
        vm.prank(management);
        _tranche.setDoHealthCheck(false);
    }

    // The vault's strategy earns `_amount`, the vault unlocks it and every tranche reports it
    function earnAndReport(
        uint256 _amount
    ) public {
        earn(_amount);
        report();
        skip(vault.profitMaxUnlockTime());
        report();
    }

    // What a tranche holds, in `asset`
    function held(
        IStrategyInterface _tranche
    ) public view returns (uint256) {
        return _tranche.balanceOfAsset() + _tranche.valueOfVault();
    }

    // For checking the amounts in the strategy
    function checkStrategyTotals(
        IStrategyInterface _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public {
        uint256 _assets = _strategy.totalAssets();
        uint256 _balance = ERC20(_strategy.asset()).balanceOf(address(_strategy));
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function airdrop(
        ERC20 _asset,
        address _to,
        uint256 _amount
    ) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    function setFees(
        uint16 _protocolFee,
        uint16 _performanceFee
    ) public {
        address gov = IFactory(factory).governance();

        // Need to make sure there is a protocol fee recipient to set the fee.
        vm.prank(gov);
        IFactory(factory).set_protocol_fee_recipient(gov);

        vm.prank(gov);
        IFactory(factory).set_protocol_fee_bps(_protocolFee);

        vm.prank(management);
        strategy.setPerformanceFee(_performanceFee);
    }

    function _setTokenAddrs() internal {
        tokenAddrs["WETH"] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        tokenAddrs["DAI"] = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        tokenAddrs["USDC"] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    }

}
