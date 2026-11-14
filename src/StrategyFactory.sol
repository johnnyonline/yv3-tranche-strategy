// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import {TrancheStrategy as Strategy} from "./Strategy.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";

contract StrategyFactory {

    event NewStrategy(address indexed strategy, address indexed asset);

    address public immutable emergencyAdmin;
    address public immutable management;
    address public immutable performanceFeeRecipient;
    address public immutable keeper;

    /// @notice Track the deployments. vault => senior => strategy
    mapping(address => mapping(address => address)) public deployments;

    constructor(
        address _management,
        address _performanceFeeRecipient,
        address _keeper,
        address _emergencyAdmin
    ) {
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
        emergencyAdmin = _emergencyAdmin;
    }

    modifier onlyManagement() {
        require(msg.sender == management, "!management");
        _;
    }

    /**
     * @notice Deploy a new Strategy.
     * @param _asset The underlying asset for the strategy to use.
     * @param _name The name of the tranche.
     * @param _symbol The symbol of the tranche.
     * @param _vault The vault every tranche is invested in.
     * @param _senior The tranche directly above the new one, zero for the most senior.
     * @return . The address of the new strategy.
     */
    function newStrategy(
        address _asset,
        string calldata _name,
        string calldata _symbol,
        address _vault,
        address _senior
    ) external virtual onlyManagement returns (address) {
        // tokenized strategies available setters.
        IStrategyInterface _newStrategy =
            IStrategyInterface(address(new Strategy(_asset, _name, _symbol, _vault, _senior)));

        _newStrategy.setPerformanceFeeRecipient(performanceFeeRecipient);

        _newStrategy.setKeeper(keeper);

        _newStrategy.setPendingManagement(management);

        _newStrategy.setEmergencyAdmin(emergencyAdmin);

        emit NewStrategy(address(_newStrategy), _asset);

        deployments[_vault][_senior] = address(_newStrategy);
        return address(_newStrategy);
    }

}
