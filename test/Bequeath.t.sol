// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Bequeath} from "../src/Bequeath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Deploys a Bequeath at the address whose lowest bits encode the AFTER_ADD_LIQUIDITY
/// + AFTER_REMOVE_LIQUIDITY + AFTER_SWAP permission flags so BaseHook's constructor
/// validation passes. In real Foundry tests this is `deployCodeTo(...)` with HookMiner;
/// here we use a constant address derived from the flag bits.
function _hookAddress() pure returns (address) {
    // AFTER_ADD_LIQUIDITY_FLAG (1<<10) | AFTER_REMOVE_LIQUIDITY_FLAG (1<<8) | AFTER_SWAP_FLAG (1<<6)
    return address(uint160((1 << 10) | (1 << 8) | (1 << 6)));
}

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @notice Registry + annuity unit tests for Bequeath. Real swap integration tests
/// (with full PoolManager) come in M2 once HookMiner is wired up.
contract BequeathTest is Test {
    Bequeath public hook;
    IPoolManager public poolManager;
    MockERC20 public token0;
    MockERC20 public token1;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address eve   = makeAddr("eve");

    PoolKey internal key;
    bytes32 internal pk;

    function setUp() public {
        poolManager = IPoolManager(address(0xBEEF));

        // Deploy Bequeath at a flag-encoded address so BaseHook's constructor
        // validation passes. afterAddLiquidity | afterRemoveLiquidity | afterSwap.
        address flags = _hookAddress();
        deployCodeTo("Bequeath.sol:Bequeath", abi.encode(poolManager), flags);
        hook = Bequeath(flags);

        token0 = new MockERC20();
        token1 = new MockERC20();

        // Ensure currency0 < currency1 (Uniswap invariant)
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Mint funds to alice (owner) and let her seed the buffer in tests
        token0.mint(alice, 1_000_000e18);
        vm.prank(alice);
        token0.approve(address(hook), type(uint256).max);

        // Set up a baseline endowment
        vm.prank(alice);
        hook.setEndowment(
            key, -887220, 887220, bytes32(0),
            bob,                // beneficiary
            1_000e18,           // monthly payout
            90 days             // heartbeat interval
        );
        pk = hook.getPositionKey(alice, key, -887220, 887220, bytes32(0));
    }

    // ─────────────── setEndowment ───────────────

    function test_setEndowment_storesState() public view {
        (address owner, address beneficiary,
         uint128 buffer, uint128 monthlyPayout, uint64 lastPayoutTime,
         uint64 heartbeatInterval, uint64 lastHeartbeat, bool active) = hook.endowments(pk);

        assertEq(owner, alice);
        assertEq(beneficiary, bob);
        assertEq(monthlyPayout, 1_000e18);
        assertEq(heartbeatInterval, 90 days);
        assertEq(lastHeartbeat, uint64(block.timestamp));
        assertEq(lastPayoutTime, uint64(block.timestamp));
        assertEq(buffer, 0);
        assertTrue(active);
    }

    function test_setEndowment_revertsOnZeroBeneficiary() public {
        vm.prank(alice);
        vm.expectRevert(Bequeath.ZeroAddress.selector);
        hook.setEndowment(key, -887220, 887220, bytes32(0), address(0), 1_000e18, 90 days);
    }

    function test_setEndowment_revertsOnShortInterval() public {
        vm.prank(alice);
        vm.expectRevert(Bequeath.IntervalTooShort.selector);
        hook.setEndowment(key, -887220, 887220, bytes32(0), bob, 1_000e18, 1 hours);
    }

    // ─────────────── deposit (annuity buffer) ───────────────

    function test_deposit_increasesBuffer() public {
        vm.prank(alice);
        hook.deposit(pk, 5_000e18);

        (, , uint128 buffer, , , , , ) = hook.endowments(pk);
        assertEq(buffer, 5_000e18);
        assertEq(token0.balanceOf(address(hook)), 5_000e18);
    }

    // ─────────────── collectMonthly ───────────────

    function test_collectMonthly_revertsBefore30Days() public {
        vm.prank(alice);
        hook.deposit(pk, 5_000e18);

        skip(29 days);
        vm.prank(alice);
        vm.expectRevert(Bequeath.PayoutTooSoon.selector);
        hook.collectMonthly(pk);
    }

    function test_collectMonthly_paysSmoothedAmount() public {
        vm.prank(alice);
        hook.deposit(pk, 5_000e18);

        skip(31 days);
        uint256 balBefore = token0.balanceOf(alice);
        vm.prank(alice);
        uint128 paid = hook.collectMonthly(pk);

        assertEq(paid, 1_000e18, "should pay full monthlyPayout when buffer >= payout");
        assertEq(token0.balanceOf(alice) - balBefore, 1_000e18);

        (, , uint128 bufferAfter, , , , , ) = hook.endowments(pk);
        assertEq(bufferAfter, 4_000e18, "buffer should decrement by paid amount");
    }

    function test_collectMonthly_cappedByBuffer() public {
        // Only 200 in buffer, target payout is 1000 — should pay 200
        vm.prank(alice);
        hook.deposit(pk, 200e18);

        skip(31 days);
        vm.prank(alice);
        uint128 paid = hook.collectMonthly(pk);
        assertEq(paid, 200e18, "should cap payout at available buffer");

        (, , uint128 bufferAfter, , , , , ) = hook.endowments(pk);
        assertEq(bufferAfter, 0);
    }

    function test_collectMonthly_revertsOnEmptyBuffer() public {
        skip(31 days);
        vm.prank(alice);
        vm.expectRevert(Bequeath.NothingToPayout.selector);
        hook.collectMonthly(pk);
    }

    function test_collectMonthly_refreshesHeartbeat() public {
        vm.prank(alice);
        hook.deposit(pk, 2_000e18);

        skip(31 days);
        vm.prank(alice);
        hook.collectMonthly(pk);

        (, , , , , , uint64 lastHeartbeat, ) = hook.endowments(pk);
        assertEq(lastHeartbeat, uint64(block.timestamp));
    }

    // ─────────────── ping ───────────────

    function test_ping_refreshesHeartbeat() public {
        skip(30 days);
        vm.prank(alice);
        hook.ping(pk);
        (, , , , , , uint64 lastHeartbeat, ) = hook.endowments(pk);
        assertEq(lastHeartbeat, uint64(block.timestamp));
    }

    function test_ping_revertsForNonOwner() public {
        vm.prank(eve);
        vm.expectRevert(Bequeath.NotOwner.selector);
        hook.ping(pk);
    }

    // ─────────────── claim (inheritance) ───────────────

    function test_claim_revertsBeforeInterval() public {
        skip(89 days);
        vm.prank(bob);
        vm.expectRevert(Bequeath.StillAlive.selector);
        hook.claim(pk);
    }

    function test_claim_revertsForNonBeneficiary() public {
        skip(91 days);
        vm.prank(eve);
        vm.expectRevert(Bequeath.NotBeneficiary.selector);
        hook.claim(pk);
    }

    function test_claim_succeedsAfterInterval_transfersOwnership() public {
        skip(91 days);
        vm.prank(bob);
        hook.claim(pk);

        (address newOwner, , , , , , , bool active) = hook.endowments(pk);
        assertEq(newOwner, bob, "beneficiary becomes new owner");
        assertTrue(active, "annuity stream stays active for the heir");
    }

    function test_claim_beneficiaryCanThenCollect() public {
        // Seed the buffer first
        vm.prank(alice);
        hook.deposit(pk, 3_000e18);

        // Skip past inheritance interval
        skip(91 days);
        vm.prank(bob);
        hook.claim(pk);

        // Bob is now owner; cadence guard means he must wait 30 days from his claim
        // (lastPayoutTime was set at setEndowment, so 91 days ago — already eligible)
        vm.prank(bob);
        uint128 paid = hook.collectMonthly(pk);
        assertEq(paid, 1_000e18);
        assertEq(token0.balanceOf(bob), 1_000e18);
    }

    // ─────────────── revoke ───────────────

    function test_revoke_marksInactiveAndRefundsBuffer() public {
        vm.prank(alice);
        hook.deposit(pk, 2_000e18);

        uint256 balBefore = token0.balanceOf(alice);
        vm.prank(alice);
        hook.revoke(pk);

        (, , , , , , , bool active) = hook.endowments(pk);
        assertFalse(active);
        assertEq(token0.balanceOf(alice) - balBefore, 2_000e18, "buffer should be refunded");
    }

    // ─────────────── isClaimable view ───────────────

    function test_isClaimable_falseBeforeInterval() public view {
        assertFalse(hook.isClaimable(pk));
    }

    function test_isClaimable_trueAfterInterval() public {
        skip(91 days);
        assertTrue(hook.isClaimable(pk));
    }
}
