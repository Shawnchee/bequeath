// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {Bequeath} from "../src/Bequeath.sol";

/// @notice Integration tests that drive Bequeath through a REAL Uniswap v4 PoolManager.
///
/// `Bequeath.t.sol` unit-tests the external API (setEndowment / deposit / collectMonthly /
/// claim / ...) against a *dummy* manager and never exercises the hook callbacks. These tests
/// close that gap: they initialize a real pool with the hook attached, then perform real swaps
/// and liquidity events and assert the callbacks fired and mutated endowment state.
///
/// Key v4 reality (confirmed by the security model): inside a hook callback the `sender`
/// argument is the ROUTER that unlocked the PoolManager — never the human LP. Bequeath's MVP
/// keys endowments and gates accrual on `sender`, so to drive the real accrual path these tests
/// own the endowment *as the router address*. Production (v1.5) carries the true owner in
/// `hookData` and checks against that instead — see the roadmap in PRD.md / README.md.
contract BequeathIntegrationTest is Deployers {
    Bequeath internal hook;

    address internal beneficiary = makeAddr("beneficiary");

    // Full-range sentinel ticks: this is the default position key afterSwap computes when no
    // hookData is supplied (see Bequeath._afterSwap).
    int24 internal constant FULL_RANGE_LOWER = type(int24).min;
    int24 internal constant FULL_RANGE_UPPER = type(int24).max;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Deploy Bequeath at an address whose low bits encode its three permission flags, so
        // BaseHook's constructor validation and the PoolManager both accept it.
        uint160 flags =
            uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddr = address(flags);
        deployCodeTo("Bequeath.sol:Bequeath", abi.encode(manager), hookAddr);
        hook = Bequeath(hookAddr);

        // Real pool with the hook attached, seeded with liquidity to swap against.
        (key,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _buffer(bytes32 pk) internal view returns (uint128 buffer) {
        (,, buffer,,,,,) = hook.endowments(pk);
    }

    function _lastHeartbeat(bytes32 pk) internal view returns (uint64 hb) {
        (,,,,,, hb,) = hook.endowments(pk);
    }

    // ───────────────────────── afterSwap accrual ───────────────────────

    /// @dev THE headline integration test: a real swap through the PoolManager fires
    /// `afterSwap`, which credits ANNUITY_CUT_BPS (1%) of the swap input to the position's
    /// annuity buffer and refreshes the heartbeat. This is the exact path the unit suite
    /// cannot reach because it has no live manager.
    function test_realSwap_accruesBufferAndRefreshesHeartbeat() public {
        // Endowment owned by the swap router — the `sender` the hook sees on this swap.
        vm.prank(address(swapRouter));
        hook.setEndowment(key, FULL_RANGE_LOWER, FULL_RANGE_UPPER, bytes32(0), beneficiary, 1_000e18, 90 days);

        bytes32 pk =
            hook.getPositionKey(address(swapRouter), key, FULL_RANGE_LOWER, FULL_RANGE_UPPER, bytes32(0));

        // Advance the clock so the heartbeat refresh is observable.
        skip(10 days);
        assertEq(_buffer(pk), 0, "buffer starts empty");

        // Real exact-input swap: 1e15 of token0 -> token1.
        int256 amountIn = 1e15;
        swap(key, true, -amountIn, "");

        // afterSwap credited 1% of the requested input notionally to the buffer (MVP accounting;
        // v1.5 settles real tokens via BalanceDelta) ...
        assertEq(_buffer(pk), uint128(uint256(amountIn) / 100), "1% of swap input accrued to buffer");
        // ... and recorded that the owner is alive.
        assertEq(_lastHeartbeat(pk), uint64(block.timestamp), "swap activity refreshed the heartbeat");
    }

    /// @dev A swap from a party with no active endowment must NOT accrue and must NOT revert —
    /// the hook can never brick the pool. (Security: afterSwap returns cleanly on the guard.)
    function test_realSwap_neverBricksPoolWithoutEndowment() public {
        bytes32 pk =
            hook.getPositionKey(address(swapRouter), key, FULL_RANGE_LOWER, FULL_RANGE_UPPER, bytes32(0));

        // No endowment configured for the router — swap should still succeed.
        swap(key, true, -1e15, "");

        assertEq(_buffer(pk), 0, "no accrual without an active endowment");
    }

    // ───────────────────── afterAddLiquidity heartbeat ─────────────────

    /// @dev Adding liquidity fires `afterAddLiquidity`, which refreshes the owner's heartbeat —
    /// the dead-man switch resets on real pool activity, not just manual ping().
    function test_realAddLiquidity_refreshesHeartbeat() public {
        // Endowment owned by the liquidity router at the LIQUIDITY_PARAMS position (-120..120).
        vm.prank(address(modifyLiquidityRouter));
        hook.setEndowment(key, -120, 120, bytes32(0), beneficiary, 1_000e18, 90 days);
        bytes32 pk = hook.getPositionKey(address(modifyLiquidityRouter), key, -120, 120, bytes32(0));

        skip(15 days);

        // More liquidity into the same position -> afterAddLiquidity -> heartbeat refresh.
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);

        assertEq(_lastHeartbeat(pk), uint64(block.timestamp), "liquidity activity refreshed the heartbeat");
    }
}
