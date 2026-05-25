// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

// Use the same import prefix as BaseHook so types match (solc dedupes by import string)
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Bequeath — DeFi pension with inheritance
/// @notice A Uniswap v4 hook that converts lumpy LP fee accrual into a predictable
/// monthly annuity payout, and lets owners designate a beneficiary who inherits
/// the income stream if the owner stops collecting (heartbeat-based dead-man switch).
/// @dev MVP design notes are documented inline; v1.5 items live in the PRD roadmap.
contract Bequeath is BaseHook {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    // ───────────────────────────── Types ─────────────────────────────

    struct Endowment {
        address owner;              // current owner (initially the LP, becomes beneficiary on claim)
        address beneficiary;        // who can claim after heartbeat expires

        // Annuity
        uint128 buffer;             // accumulated fees held by the hook for this position
        uint128 monthlyPayout;      // target steady payout per PAYOUT_PERIOD
        uint64  lastPayoutTime;     // unix timestamp of last collectMonthly()

        // Inheritance
        uint64  heartbeatInterval;  // seconds of inactivity before claim is allowed
        uint64  lastHeartbeat;      // unix timestamp of last activity / ping

        bool    active;             // false once revoked
    }

    // ───────────────────────────── State ─────────────────────────────

    /// @dev positionKey => Endowment
    /// positionKey = keccak256(owner, poolId, tickLower, tickUpper, salt)
    mapping(bytes32 => Endowment) public endowments;

    /// @dev Each endowment remembers which currency its buffer is denominated in.
    /// MVP: a single annuity is paid in token0 of the pool.
    mapping(bytes32 => Currency) public payoutCurrency;

    /// @dev Default heartbeat interval if owner doesn't set one explicitly.
    uint64 public constant DEFAULT_INTERVAL = 90 days;

    /// @dev The smallest heartbeat interval users may pick (avoid accidental triggers).
    uint64 public constant MIN_INTERVAL = 1 days;

    /// @dev Annuity payout cadence — owner can collect at most once per PAYOUT_PERIOD.
    uint64 public constant PAYOUT_PERIOD = 30 days;

    /// @dev MVP: cut of swap input (in basis points) the hook records as accrued to the
    /// position's annuity buffer. In v1.5 this becomes a real settle via afterSwap delta.
    uint16 public constant ANNUITY_CUT_BPS = 100; // 1%

    // ───────────────────────────── Events ────────────────────────────

    event EndowmentCreated(
        bytes32 indexed positionKey,
        address indexed owner,
        address indexed beneficiary,
        uint128 monthlyPayout,
        uint64 heartbeatInterval
    );
    event BufferAccrued(bytes32 indexed positionKey, uint128 amount, uint128 newBuffer);
    event PayoutCollected(bytes32 indexed positionKey, address indexed to, uint128 amount);
    event Heartbeat(bytes32 indexed positionKey, uint64 timestamp);
    event Claimed(bytes32 indexed positionKey, address indexed beneficiary);
    event EndowmentRevoked(bytes32 indexed positionKey);

    // ───────────────────────────── Errors ────────────────────────────

    error NotOwner();
    error NotBeneficiary();
    error StillAlive();
    error NoActiveEndowment();
    error ZeroAddress();
    error IntervalTooShort();
    error PayoutTooSoon();
    error NothingToPayout();

    // ─────────────────────────── Constructor ─────────────────────────

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // ─────────────────────────── Permissions ─────────────────────────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,    // heartbeat refresh + currency registration
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true, // heartbeat refresh
            beforeSwap: false,
            afterSwap: true,            // accumulate to annuity buffer + heartbeat
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─────────────────────────── Hook Callbacks ──────────────────────

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        bytes32 pk = _positionKey(sender, key, params.tickLower, params.tickUpper, params.salt);
        if (Currency.unwrap(payoutCurrency[pk]) == address(0)) {
            payoutCurrency[pk] = key.currency0;
        }
        _refreshHeartbeat(pk, sender);
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        bytes32 pk = _positionKey(sender, key, params.tickLower, params.tickUpper, params.salt);
        _refreshHeartbeat(pk, sender);
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @dev On every swap, refresh heartbeat for the sender's endowment in this pool
    /// (positionKey defaults to a sentinel full-range / salt=0 position unless caller
    /// passes one via hookData) and credit a small annuity cut to its buffer.
    /// MVP simplification: accounting only — `deposit()` mirrors real token flow.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        bytes32 pk = hookData.length == 32
            ? abi.decode(hookData, (bytes32))
            : _positionKey(sender, key, type(int24).min, type(int24).max, bytes32(0));

        Endowment storage e = endowments[pk];
        if (!e.active || e.owner != sender) {
            return (BaseHook.afterSwap.selector, 0);
        }

        // Refresh heartbeat — owner is clearly alive
        e.lastHeartbeat = uint64(block.timestamp);
        emit Heartbeat(pk, e.lastHeartbeat);

        // Credit annuity buffer with ANNUITY_CUT_BPS of the absolute swap amount.
        uint256 absAmount = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);
        uint128 cut = uint128((absAmount * ANNUITY_CUT_BPS) / 10_000);
        if (cut > 0) {
            e.buffer += cut;
            emit BufferAccrued(pk, cut, e.buffer);
        }
        return (BaseHook.afterSwap.selector, 0);
    }

    // ─────────────────────────── External API ────────────────────────

    /// @notice Configure an endowment for a position you own.
    function setEndowment(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        address beneficiary,
        uint128 monthlyPayout,
        uint64 heartbeatInterval
    ) external {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (heartbeatInterval < MIN_INTERVAL) revert IntervalTooShort();

        bytes32 pk = _positionKey(msg.sender, key, tickLower, tickUpper, salt);
        Endowment storage e = endowments[pk];

        if (e.owner != address(0) && e.owner != msg.sender) revert NotOwner();

        e.owner = msg.sender;
        e.beneficiary = beneficiary;
        e.monthlyPayout = monthlyPayout;
        e.heartbeatInterval = heartbeatInterval;
        e.lastHeartbeat = uint64(block.timestamp);
        e.lastPayoutTime = uint64(block.timestamp);
        e.active = true;

        if (Currency.unwrap(payoutCurrency[pk]) == address(0)) {
            payoutCurrency[pk] = key.currency0;
        }

        emit EndowmentCreated(pk, msg.sender, beneficiary, monthlyPayout, heartbeatInterval);
    }

    /// @notice Owner manually refreshes the heartbeat. Useful for passive holders.
    function ping(bytes32 positionKey) external {
        Endowment storage e = endowments[positionKey];
        if (!e.active) revert NoActiveEndowment();
        if (e.owner != msg.sender) revert NotOwner();
        e.lastHeartbeat = uint64(block.timestamp);
        emit Heartbeat(positionKey, e.lastHeartbeat);
    }

    /// @notice Voluntary deposit to seed the annuity buffer (MVP — mirrors what
    /// afterSwap would settle on-chain in v1.5 via hookDelta).
    function deposit(bytes32 positionKey, uint128 amount) external {
        Endowment storage e = endowments[positionKey];
        if (!e.active) revert NoActiveEndowment();
        Currency c = payoutCurrency[positionKey];
        IERC20(Currency.unwrap(c)).safeTransferFrom(msg.sender, address(this), amount);
        e.buffer += amount;
        emit BufferAccrued(positionKey, amount, e.buffer);
    }

    /// @notice Owner (or post-claim beneficiary) pulls the monthly payout. Gated to once
    /// per PAYOUT_PERIOD. Returns min(monthlyPayout, buffer) — never overdraws.
    function collectMonthly(bytes32 positionKey) external returns (uint128 paid) {
        Endowment storage e = endowments[positionKey];
        if (!e.active) revert NoActiveEndowment();
        if (e.owner != msg.sender) revert NotOwner();
        if (block.timestamp < e.lastPayoutTime + PAYOUT_PERIOD) revert PayoutTooSoon();
        if (e.buffer == 0) revert NothingToPayout();

        paid = e.monthlyPayout < e.buffer ? e.monthlyPayout : e.buffer;
        e.buffer -= paid;
        e.lastPayoutTime = uint64(block.timestamp);
        e.lastHeartbeat = uint64(block.timestamp); // collecting = alive

        Currency c = payoutCurrency[positionKey];
        IERC20(Currency.unwrap(c)).safeTransfer(msg.sender, paid);

        emit PayoutCollected(positionKey, msg.sender, paid);
    }

    /// @notice Beneficiary claims the annuity stream after the heartbeat expires.
    /// Becomes the new owner — can collect future monthly payouts and set a new beneficiary.
    function claim(bytes32 positionKey) external {
        Endowment storage e = endowments[positionKey];
        if (!e.active) revert NoActiveEndowment();
        if (msg.sender != e.beneficiary) revert NotBeneficiary();
        if (block.timestamp - e.lastHeartbeat <= e.heartbeatInterval) revert StillAlive();

        e.owner = msg.sender;
        e.lastHeartbeat = uint64(block.timestamp);
        // active stays true so the heir can keep collecting
        emit Claimed(positionKey, msg.sender);
    }

    /// @notice Owner revokes the endowment entirely. Buffer is refunded to owner.
    function revoke(bytes32 positionKey) external {
        Endowment storage e = endowments[positionKey];
        if (!e.active) revert NoActiveEndowment();
        if (e.owner != msg.sender) revert NotOwner();

        uint128 refund = e.buffer;
        e.buffer = 0;
        e.active = false;

        if (refund > 0) {
            Currency c = payoutCurrency[positionKey];
            IERC20(Currency.unwrap(c)).safeTransfer(msg.sender, refund);
        }
        emit EndowmentRevoked(positionKey);
    }

    // ─────────────────────────── Views ───────────────────────────────

    function isClaimable(bytes32 positionKey) external view returns (bool) {
        Endowment memory e = endowments[positionKey];
        if (!e.active) return false;
        return block.timestamp - e.lastHeartbeat > e.heartbeatInterval;
    }

    function nextPayoutTime(bytes32 positionKey) external view returns (uint64) {
        return endowments[positionKey].lastPayoutTime + PAYOUT_PERIOD;
    }

    function getPositionKey(
        address owner,
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) external pure returns (bytes32) {
        return _positionKey(owner, key, tickLower, tickUpper, salt);
    }

    // ─────────────────────────── Internal ────────────────────────────

    function _positionKey(
        address owner,
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, key.toId(), tickLower, tickUpper, salt));
    }

    function _refreshHeartbeat(bytes32 pk, address sender) internal {
        Endowment storage e = endowments[pk];
        if (e.active && e.owner == sender) {
            e.lastHeartbeat = uint64(block.timestamp);
            emit Heartbeat(pk, e.lastHeartbeat);
        }
    }
}
