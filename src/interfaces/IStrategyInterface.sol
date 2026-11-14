// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IBaseHealthCheck} from "@periphery/Bases/HealthCheck/IBaseHealthCheck.sol";

interface IStrategyInterface is IBaseHealthCheck {

    // ===============================================================
    // Views
    // ===============================================================

    function MAX_COOLDOWN_DURATION() external view returns (uint256);

    function MIN_WITHDRAWAL_WINDOW() external view returns (uint256);

    function SENIOR() external view returns (address);

    function VAULT() external view returns (address);

    function premium() external view returns (uint256);

    function cooldownDuration() external view returns (uint256);

    function withdrawalWindow() external view returns (uint256);

    function junior() external view returns (address);

    function cooldowns(
        address _user
    ) external view returns (uint64 cooldownEnd, uint64 windowEnd, uint128 shares);

    function balanceOfAsset() external view returns (uint256);

    function balanceOfVault() external view returns (uint256);

    function valueOfVault() external view returns (uint256);

    // ===============================================================
    // Management
    // ===============================================================

    function setJunior(
        address _junior
    ) external;

    function setPremium(
        uint256 _premium
    ) external;

    function setCooldown(
        uint256 _cooldownDuration,
        uint256 _withdrawalWindow
    ) external;

    // ===============================================================
    // Tranches
    // ===============================================================

    function cover(
        uint256 _assets
    ) external;

    // ===============================================================
    // Cooldown
    // ===============================================================

    function startCooldown(
        uint256 _shares
    ) external;

    function cancelCooldown() external;

}
