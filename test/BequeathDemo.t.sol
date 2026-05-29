// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Bequeath} from "../src/Bequeath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract DemoToken is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @notice The "shoot script" for the demo video. This is NOT a normal unit test — it is a
/// single narrative scenario, written to be read aloud while `forge test -vvv` streams the
/// console output. Run it alone:
///
///     forge test --match-test test_demo_pensionThatOutlivesYou -vvv
///
/// It plays one Bequeath position across THREE generations — retiree -> spouse -> daughter —
/// proving the tagline literally: a DeFi pension that smooths lumpy yield AND survives the
/// death of its owner, passing the income stream down instead of freezing it.
contract BequeathDemoTest is Test {
    Bequeath internal hook;
    DemoToken internal usdc;

    address internal alice = makeAddr("alice"); // the retiree
    address internal bob   = makeAddr("bob");   // her spouse  (generation 2)
    address internal carol = makeAddr("carol"); // their daughter (generation 3)
    address internal eve   = makeAddr("eve");   // an opportunistic stranger

    PoolKey internal key;
    bytes32 internal pk;

    uint128 internal constant MONTHLY = 1_000e18;   // $1,000/month pension
    uint128 internal constant PRINCIPAL = 100_000e18; // accrued fees backing the annuity

    function setUp() public {
        // Deploy the hook at a permission-flag-encoded address (afterAddLiquidity | afterRemove | afterSwap).
        address flags = address(uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG));
        deployCodeTo("Bequeath.sol:Bequeath", abi.encode(IPoolManager(address(0xBEEF))), flags);
        hook = Bequeath(flags);

        usdc = new DemoToken();
        key = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(0xCAFE)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Fund Alice and let her seed the annuity buffer.
        usdc.mint(alice, PRINCIPAL);
        vm.prank(alice);
        usdc.approve(address(hook), type(uint256).max);
    }

    function _buffer() internal view returns (uint128 b) { (,, b,,,,,) = hook.endowments(pk); }
    function _owner() internal view returns (address o) { (o,,,,,,,) = hook.endowments(pk); }
    function _bal(address who) internal view returns (uint256) { return usdc.balanceOf(who) / 1e18; }

    function test_demo_pensionThatOutlivesYou() public {
        console2.log("==================================================================");
        console2.log("  BEQUEATH - the first DeFi pension that outlives you");
        console2.log("==================================================================");

        // ─────────────────── GENERATION 1: the retiree ───────────────────
        console2.log("");
        console2.log("[ YEAR 0 ] Alice retires and turns her LP position into a pension.");
        vm.prank(alice);
        hook.setEndowment(key, -887220, 887220, bytes32(0), bob, MONTHLY, 90 days);
        pk = hook.getPositionKey(alice, key, -887220, 887220, bytes32(0));

        // In production swaps fill this buffer via afterSwap; here Alice seeds it directly (MVP).
        vm.prank(alice);
        hook.deposit(pk, PRINCIPAL);

        console2.log("  Principal backing the annuity (USDC):", _buffer() / 1e18);
        console2.log("  Target pension per month (USDC):     ", uint256(MONTHLY) / 1e18);
        console2.log("  Named heir: Bob (her spouse). Heartbeat: 90 days of silence = inheritance.");

        // Three months of life on the pension. Markets swing wildly; her income does not.
        console2.log("");
        console2.log("[ LIVING ] Lumpy market, FLAT pension - the whole point:");
        for (uint256 m = 1; m <= 3; m++) {
            skip(31 days);
            vm.prank(alice);
            uint128 paid = hook.collectMonthly(pk);
            console2.log("   month", m);
            console2.log("     -> Alice receives (USDC):", uint256(paid) / 1e18);
        }
        console2.log("  Alice's wallet after 3 months (USDC):", _bal(alice));

        // ─────────────────────── THE SILENCE ───────────────────────
        console2.log("");
        console2.log("[ SILENCE ] Alice passes away. No transactions. The chain notices.");
        skip(91 days);
        console2.log("  91 days of inactivity. Claimable by heir? ", hook.isClaimable(pk));

        // ─────────────────────── THE IMPOSTER ──────────────────────
        console2.log("");
        console2.log("[ ATTACK ] A stranger (Eve) tries to seize the stream...");
        vm.prank(eve);
        vm.expectRevert(Bequeath.NotBeneficiary.selector);
        hook.claim(pk);
        console2.log("  -> REJECTED. Only the named beneficiary can ever claim.");

        // ─────────────────── GENERATION 2: the spouse ──────────────────
        console2.log("");
        console2.log("[ INHERIT ] Bob, her spouse, claims. Not a frozen NFT - a LIVING income stream.");
        vm.prank(bob);
        hook.claim(pk);
        console2.log("  New owner of the pension:", _owner());

        skip(31 days);
        vm.prank(bob);
        uint128 bobPaid = hook.collectMonthly(pk);
        console2.log("  Bob now collects the pension (USDC):", uint256(bobPaid) / 1e18);

        // Succession: Bob names the next generation.
        vm.prank(bob);
        hook.setBeneficiary(pk, carol);
        console2.log("  Bob names their daughter Carol as the next heir.");

        // ─────────────────── GENERATION 3: the daughter ─────────────────
        console2.log("");
        console2.log("[ TIME ] Years pass. Bob goes silent too.");
        skip(91 days);
        console2.log("  Claimable again? ", hook.isClaimable(pk));

        vm.prank(carol);
        hook.claim(pk);
        skip(31 days);
        vm.prank(carol);
        uint128 carolPaid = hook.collectMonthly(pk);
        console2.log("  Carol inherits and collects (USDC):", uint256(carolPaid) / 1e18);

        // ─────────────────────────── EPILOGUE ──────────────────────────
        console2.log("");
        console2.log("==================================================================");
        console2.log("  One position. Three generations. The yield never died.");
        console2.log("  Buffer still funding the stream (USDC):", _buffer() / 1e18);
        console2.log("==================================================================");

        // Assertions so this also stands as a real regression test of the full lifecycle.
        assertEq(_owner(), carol, "stream ended with the daughter");
        assertEq(bobPaid, MONTHLY, "heir collects the same smoothed pension");
        assertEq(carolPaid, MONTHLY, "third generation collects too");
        assertEq(_bal(alice), 3_000, "Alice drew 3 flat months");
    }
}
