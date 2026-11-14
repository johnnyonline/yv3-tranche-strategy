// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategy} from "@tokenized-strategy/BaseStrategy.sol";

/// @notice Vault strategy that just holds idle `asset`
/// @dev Tests airdrop `asset` to it, or pull `asset` out of it, to make the vault earn or lose
contract MockStrategy is BaseStrategy {

    /// @notice What the vault can pull out, to make it illiquid
    uint256 public withdrawLimit = type(uint256).max;

    constructor(
        address _asset
    ) BaseStrategy(_asset, "Mock Strategy") {}

    function setWithdrawLimit(
        uint256 _withdrawLimit
    ) external {
        withdrawLimit = _withdrawLimit;
    }

    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        return withdrawLimit;
    }

    function _deployFunds(
        uint256 /*_amount*/
    ) internal override {}

    function _freeFunds(
        uint256 /*_amount*/
    ) internal override {}

    function _harvestAndReport() internal view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

}
