// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Script.sol";

import {IVault} from "@yearn-vaults/interfaces/IVault.sol";

import {IStrategyInterface} from "../src/interfaces/IStrategyInterface.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";

// ---- Usage ----

// deploy:
// forge script script/Deploy.s.sol:Deploy --verify -g 250 --slow --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

contract Deploy is Script {

    bool public isTest;
    address public s_management;
    address public s_performanceFeeRecipient;
    address public s_keeper;
    address public s_emergencyAdmin;
    IVault public s_vault;
    StrategyFactory public s_factory;
    IStrategyInterface public s_trancheA;
    IStrategyInterface public s_trancheB;
    IStrategyInterface public s_trancheE;

    address public constant SMS = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7; // SMS mainnet
    address public constant ACCOUNTANT = 0x5A74Cb32D36f2f517DB6f7b0A0591e09b22cDE69; // SMS mainnet accountant
    address public constant DEPLOYER = 0x420ACF637D662b80cca8bEfb327AA24039E7e0Fa; // gm.johnnyonline.eth
    address public constant YHAAS = 0x604e586F17cE106B64185A7a0d2c1Da5bAce711E; // yHAAS
    IVault public constant YVUSD = IVault(0x696d02Db93291651ED510704c9b286841d506987); // USD yVault, v3.0.4

    uint256 public constant PREMIUM_A = 2_000; // A passes 20% of its profit down to B
    uint256 public constant PREMIUM_B = 5_000; // B passes 50% of its profit down to E

    function run() public {
        uint256 _pk = isTest ? 42069 : vm.envUint("DEPLOYER_PRIVATE_KEY");
        address _deployer = vm.addr(_pk);

        if (!isTest) {
            require(_deployer == DEPLOYER, "!deployer");

            s_management = SMS;
            s_performanceFeeRecipient = ACCOUNTANT;
            s_keeper = YHAAS;
            s_emergencyAdmin = SMS;
            s_vault = YVUSD;
        }

        vm.startBroadcast(_pk);

        // deploy. The deployer manages the factory and hands each tranche over to `s_management`
        // TODO: the tranche names and symbols are temporary, final ones TBD
        s_factory = new StrategyFactory(_deployer, s_performanceFeeRecipient, s_keeper, s_emergencyAdmin);
        s_trancheA = _newTranche("Tranche A", "yvUSD-A", address(0));
        s_trancheB = _newTranche("Tranche B", "yvUSD-B", address(s_trancheA));
        s_trancheE = _newTranche("Tranche E", "yvUSD-E", address(s_trancheB));

        // init tranches. Cover is pulled up E -> B -> A, premiums are passed down A -> B -> E
        _initTranche(s_trancheA, address(s_trancheB), PREMIUM_A, 0); // No cooldown
        _initTranche(s_trancheB, address(s_trancheE), PREMIUM_B, 14 days);
        _initTranche(s_trancheE, address(0), 0, 30 days);

        vm.stopBroadcast();

        if (!isTest) {
            console.log("Factory address: %s", address(s_factory));
            console.log("Tranche A address: %s", address(s_trancheA));
            console.log("Tranche B address: %s", address(s_trancheB));
            console.log("Tranche E address: %s", address(s_trancheE));
        }
    }

    function _newTranche(
        string memory _name,
        string memory _symbol,
        address _senior
    ) internal returns (IStrategyInterface) {
        return IStrategyInterface(s_factory.newStrategy(s_vault.asset(), _name, _symbol, address(s_vault), _senior));
    }

    function _initTranche(
        IStrategyInterface _tranche,
        address _junior,
        uint256 _premium,
        uint256 _cooldownDuration
    ) internal {
        _tranche.acceptManagement();
        _tranche.setJunior(_junior);
        _tranche.setPremium(_premium);
        if (_cooldownDuration != 0) _tranche.setCooldown(_cooldownDuration);
        _tranche.setProfitMaxUnlockTime(2 days);
        _tranche.setPerformanceFee(0);
        _tranche.setOpen(true);
        _tranche.setPendingManagement(s_management);
    }

}
