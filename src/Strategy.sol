// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseStrategy} from "@tokenized-strategy/BaseStrategy.sol";
import {TokenizedStrategyLib as TokenizedStrategy} from "@tokenized-strategy/libraries/TokenizedStrategyLib.sol";
import {BaseHooks, BaseHealthCheck, ERC20} from "@periphery/Bases/Hooks/BaseHooks.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";

import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";

contract TrancheStrategy is BaseHooks {

    using SafeERC20 for ERC20;
    using SafeERC20 for IVault;

    // ===============================================================
    // Structs
    // ===============================================================

    /// @notice A user's pending cooldown
    /// @param cooldownEnd Timestamp the shares become withdrawable at
    /// @param windowEnd Timestamp the shares stop being withdrawable at
    /// @param shares Amount of shares cooling down
    struct UserCooldown {
        uint64 cooldownEnd;
        uint64 windowEnd;
        uint128 shares;
    }

    // ===============================================================
    // Events
    // ===============================================================

    event JuniorSet(address indexed junior);
    event PremiumSet(uint256 premium);
    event CooldownSet(uint256 cooldownDuration, uint256 withdrawalWindow);
    event CooldownStarted(address indexed user, uint256 shares, uint256 cooldownEnd, uint256 windowEnd);
    event CooldownCancelled(address indexed user);

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice Longest cooldown management can set
    uint256 public constant MAX_COOLDOWN_DURATION = 90 days;

    /// @notice Shortest withdrawal window management can set
    uint256 public constant MIN_WITHDRAWAL_WINDOW = 7 days;

    /// @notice Yearn V3 vault every tranche is invested in
    IVault public immutable VAULT;

    /// @notice Tranche directly above this one, the only caller of `cover`. Zero for the most senior
    IStrategyInterface public immutable SENIOR;

    // ===============================================================
    // Storage
    // ===============================================================

    /// @notice Symbol of the tranche. Replaces the TokenizedStrategy default
    string public symbol;

    /// @notice Share of reported profit passed down to `junior`, in basis points
    uint256 public premium;

    /// @notice Seconds between `startCooldown` and the shares becoming withdrawable. Zero means no cooldown
    uint256 public cooldownDuration;

    /// @notice Seconds the shares stay withdrawable for once their cooldown is over
    uint256 public withdrawalWindow;

    /// @notice Tranche directly below this one, which pays cover before this one does. Zero for the most junior
    IStrategyInterface public junior;

    /// @notice Pending cooldown of each user
    mapping(address => UserCooldown) public cooldowns;

    // ===============================================================
    // Constructor
    // ===============================================================

    /// @param _asset Address of the vault's asset
    /// @param _name Name of the tranche
    /// @param _symbol Symbol of the tranche
    /// @param _vault Address of the vault every tranche is invested in
    /// @param _senior Address of the tranche directly above this one, zero for the most senior
    constructor(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _vault,
        address _senior
    ) BaseHealthCheck(_asset, _name) {
        VAULT = IVault(_vault);
        require(VAULT.asset() == _asset, "!vault");

        SENIOR = IStrategyInterface(_senior);
        require(_senior == address(0) || SENIOR.VAULT() == _vault, "!senior");

        symbol = _symbol;

        // Let the vault pull `asset`
        asset.forceApprove(_vault, type(uint256).max);
    }

    // ===============================================================
    // View functions
    // ===============================================================

    /// @notice Idle `asset` held by the tranche
    /// @return Amount of `asset`
    function balanceOfAsset() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Vault shares held by the tranche
    /// @return Amount of vault shares
    function balanceOfVault() public view returns (uint256) {
        return VAULT.balanceOf(address(this));
    }

    /// @notice What the tranche's vault shares are worth
    /// @return Amount of `asset`
    function valueOfVault() public view returns (uint256) {
        return VAULT.convertToAssets(balanceOfVault());
    }

    /// @inheritdoc BaseStrategy
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        return Math.min(BaseHealthCheck.availableDepositLimit(_owner), VAULT.maxDeposit(address(this)));
    }

    /// @inheritdoc BaseStrategy
    function availableWithdrawLimit(
        address _owner
    ) public view override returns (uint256) {
        // What the vault can pay out right now, whatever the loss
        uint256 _limit = balanceOfAsset() + VAULT.maxWithdraw(address(this), MAX_BPS);

        if (cooldownDuration == 0 || TokenizedStrategy.isShutdown()) return _limit;

        // Only shares whose cooldown is over, and whose window is still open, can leave
        UserCooldown memory _cooldown = cooldowns[_owner];
        if (_cooldown.shares == 0) return 0;
        if (block.timestamp < _cooldown.cooldownEnd || block.timestamp > _cooldown.windowEnd) return 0;

        // Round up so that all of the cooled shares can be redeemed
        return Math.min(_limit, TokenizedStrategy.previewMint(_cooldown.shares));
    }

    // ===============================================================
    // Management functions
    // ===============================================================

    /// @notice Set the tranche directly below this one
    /// @dev It must have been deployed with this tranche as its `SENIOR`
    /// @param _junior Address of the junior tranche, zero for none
    function setJunior(
        address _junior
    ) external onlyManagement {
        require(_junior == address(0) || IStrategyInterface(_junior).SENIOR() == address(this), "!junior");
        junior = IStrategyInterface(_junior);
        emit JuniorSet(_junior);
    }

    /// @notice Set the share of reported profit passed down to `junior`
    /// @param _premium Share of the profit in basis points
    function setPremium(
        uint256 _premium
    ) external onlyManagement {
        require(_premium <= MAX_BPS, "!premium");
        premium = _premium;
        emit PremiumSet(_premium);
    }

    /// @notice Set the cooldown users go through before withdrawing
    /// @dev A duration of zero means no cooldown. Cooldowns already started keep their timestamps
    /// @param _cooldownDuration Seconds between `startCooldown` and the shares becoming withdrawable
    /// @param _withdrawalWindow Seconds the shares stay withdrawable for once their cooldown is over
    function setCooldown(
        uint256 _cooldownDuration,
        uint256 _withdrawalWindow
    ) external onlyManagement {
        require(_cooldownDuration <= MAX_COOLDOWN_DURATION, "!duration");
        require(_withdrawalWindow >= MIN_WITHDRAWAL_WINDOW, "!window");
        cooldownDuration = _cooldownDuration;
        withdrawalWindow = _withdrawalWindow;
        emit CooldownSet(_cooldownDuration, _withdrawalWindow);
    }

    // ===============================================================
    // Tranche functions
    // ===============================================================

    /// @notice Pay cover to the tranche above, taking it from the tranches below first
    /// @dev Pays whatever it holds when it cannot pay in full
    /// @param _assets Amount of `asset` the tranche above is short of
    function cover(
        uint256 _assets
    ) external {
        require(msg.sender == address(SENIOR), "!senior");

        // The most junior tranche pays first
        if (address(junior) != address(0)) junior.cover(_assets);

        // Round up so the tranche above is not left a wei short
        uint256 _shares = Math.min(VAULT.previewWithdraw(_assets), balanceOfVault());
        VAULT.safeTransfer(msg.sender, _shares);
    }

    // ===============================================================
    // Cooldown functions
    // ===============================================================

    /// @notice Start a cooldown on some of the caller's shares
    /// @dev Replaces any cooldown the caller already has
    /// @param _shares Amount of shares to cool down
    function startCooldown(
        uint256 _shares
    ) external {
        require(cooldownDuration != 0, "!cooldown");
        require(_shares != 0 && _shares <= type(uint128).max, "!shares");
        require(_shares <= TokenizedStrategy.balanceOf(msg.sender), "!balance");

        uint256 _cooldownEnd = block.timestamp + cooldownDuration;
        uint256 _windowEnd = _cooldownEnd + withdrawalWindow;
        cooldowns[msg.sender] =
            UserCooldown({cooldownEnd: uint64(_cooldownEnd), windowEnd: uint64(_windowEnd), shares: uint128(_shares)});

        emit CooldownStarted(msg.sender, _shares, _cooldownEnd, _windowEnd);
    }

    /// @notice Cancel the caller's cooldown
    function cancelCooldown() external {
        require(cooldowns[msg.sender].shares != 0, "!pending");
        delete cooldowns[msg.sender];
        emit CooldownCancelled(msg.sender);
    }

    // ===============================================================
    // Internal mutated functions
    // ===============================================================

    /// @inheritdoc BaseStrategy
    function _deployFunds(
        uint256 _amount
    ) internal override {
        VAULT.deposit(_amount, address(this));
    }

    /// @inheritdoc BaseStrategy
    function _freeFunds(
        uint256 _amount
    ) internal override {
        // Redeem the vault shares that cover `_amount`
        VAULT.redeem(Math.min(VAULT.previewWithdraw(_amount), balanceOfVault()), address(this), address(this));
    }

    /// @inheritdoc BaseStrategy
    function _harvestAndReport() internal override returns (uint256) {
        // Get topped up by the junior tranches
        _pullCover();

        // Pass a share of the profit down to the junior tranches
        uint256 _owed = TokenizedStrategy.lastTotalAssets();
        uint256 _held = balanceOfAsset() + valueOfVault();
        if (_held > _owed && address(junior) != address(0)) {
            uint256 _shares = VAULT.convertToShares((_held - _owed) * premium / MAX_BPS);
            VAULT.safeTransfer(address(junior), _shares);
        }

        return balanceOfAsset() + valueOfVault();
    }

    /// @notice Pull cover from the junior tranches if this tranche holds less than it accounts for
    function _pullCover() internal {
        if (address(junior) == address(0)) return;

        uint256 _owed = TokenizedStrategy.lastTotalAssets();
        uint256 _held = balanceOfAsset() + valueOfVault();
        if (_held < _owed) junior.cover(_owed - _held);
    }

    /// @notice Reduce the owner's cooldown by the shares they just redeemed
    function _postWithdrawHook(
        uint256, /*_assets*/
        uint256 _shares,
        address, /*_receiver*/
        address _owner,
        uint256 /*_maxLoss*/
    ) internal override {
        UserCooldown storage _cooldown = cooldowns[_owner];
        if (_cooldown.shares == 0) return;

        if (_shares >= _cooldown.shares) delete cooldowns[_owner];
        else _cooldown.shares -= uint128(_shares);
    }

    /// @notice Block the transfer of shares that are cooling down
    function _preTransferHook(
        address _from,
        address, /*_to*/
        uint256 _amount
    ) internal view override {
        if (cooldownDuration == 0 || TokenizedStrategy.isShutdown()) return;

        UserCooldown memory _cooldown = cooldowns[_from];
        if (_cooldown.shares == 0 || block.timestamp > _cooldown.windowEnd) return;

        uint256 _balance = TokenizedStrategy.balanceOf(_from);
        require(_balance >= _cooldown.shares + _amount, "!transfer");
    }

}
