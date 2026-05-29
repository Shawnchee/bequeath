# Security Notes — Bequeath

A self-audit of `src/Bequeath.sol` against the Uniswap v4 hook threat model. This is an MVP
hackathon hook; the goal here is an **honest threat model**, not a clean bill of health. Findings
are rated by their severity *in production* — several are deliberately accepted for the MVP and are
documented as such (and as roadmap items in `PRD.md` / `README.md`).

## Scope & posture

- Single immutable contract, no proxy, no admin keys, no upgrade path (eliminates the entire
  upgrade-mechanism attack surface).
- Permissions enabled: `afterAddLiquidity` (LOW), `afterRemoveLiquidity` (LOW), `afterSwap` (MEDIUM).
- **No** `*ReturnDelta` permissions — the hook never returns a custom swap/liquidity delta, so the
  critical NoOp / value-extraction attack surface (`beforeSwapReturnDelta`, `afterSwapReturnDelta`,
  etc.) is entirely absent.

## Checklist results

| # | Check | Status | Note |
|---|---|---|---|
| 1 | Callbacks verify `msg.sender == poolManager` | ✅ | Enforced by OpenZeppelin `BaseHook`; we override the internal `_afterX` only. |
| 2 | Router allowlisting / user identity | ⚠️ | See **F-1**. Uses `sender` (correct, not `msg.sender`) but treats it as the owner. |
| 3 | No unbounded loops (OOG) | ✅ | All callbacks are O(1); no iteration over positions. |
| 4 | Checks-effects-interactions / reentrancy | ✅ | `collectMonthly` and `revoke` mutate state **before** the token transfer. |
| 5 | Delta accounting sums to zero | ✅ (N/A) | Hook returns `ZERO_DELTA` / `0` — never participates in settlement. |
| 6 | Fee-on-transfer tokens handled | ⚠️ | See **F-3**. `deposit` credits the requested amount, not the received amount. |
| 7 | No hardcoded addresses | ✅ | PoolManager injected via constructor. |
| 8 | Slippage respected | ✅ (N/A) | Hook does not alter swap amounts. |
| 9 | No sensitive data on-chain | ✅ | Only owner/beneficiary/amounts/timestamps. |
| 10 | Upgrade mechanism secured | ✅ | None — immutable by design. |
| 11 | `beforeSwapReturnDelta` justified | ✅ (N/A) | Not enabled. |
| 12 | Fuzz testing | ❌ | Not yet — see Recommendations. |
| 13 | Invariant testing | ❌ | Not yet — see **F-2** (the key invariant) and Recommendations. |

## Findings

### F-1 — `sender` is the router, not the LP (MEDIUM, accepted for MVP)
Inside `_afterSwap` / `_afterAddLiquidity`, the `sender` argument is whoever unlocked the
PoolManager — a router/PositionManager in production, **never** the human LP. Bequeath keys
endowments and gates accrual/heartbeat on `sender` (`e.owner == sender`). Against a real router,
every position would key to the router address, so accrual and heartbeat refresh would not track
the true owner.
- **Impact:** annuity accrual and heartbeat refresh via callbacks are effectively MVP/direct-call
  only. The *external* API (`setEndowment`, `collectMonthly`, `claim`, …) is unaffected — those use
  `msg.sender` correctly.
- **Status:** documented MVP boundary. The integration tests intentionally own the endowment as the
  router to exercise the path. v1.5 fix: carry the true owner in `hookData` and check against the
  decoded owner (with a trusted-router allowlist), per the security skill's router-verification
  pattern.

### F-2 — Annuity buffer is not token-backed in `afterSwap` (HIGH in production, accepted for MVP)
`_afterSwap` does `e.buffer += cut` but moves **no tokens** (`afterSwapReturnDelta` is false, returns
`0`). Real tokens enter only via `deposit()`. Because all positions of the same currency share the
hook's single token balance, a buffer credited notionally by `afterSwap` is **not individually
backed** — a withdrawal against it (`collectMonthly` / `revoke`) would transfer another position's
deposited tokens (cross-position insolvency), or revert via SafeERC20 if the pool is empty.
- **Why it's not exploitable today:** accrual requires `owner == router` (F-1), and every funded path
  in the tests/demo seeds via `deposit()` (fully backed). The integration test that triggers notional
  accrual deliberately never collects.
- **The invariant to enforce:** for each currency, `sum(buffers) ≤ hook token balance`.
- **v1.5 fix:** capture real fees via `afterSwapReturnDelta` + `BalanceDelta` settlement so every
  buffer credit is backed 1:1 by tokens taken from the swap. Then the invariant holds and can be
  fuzz-tested.

### F-3 — Fee-on-transfer / rebasing tokens over-credit the buffer (LOW)
`deposit` credits `amount` rather than the actual balance delta. A fee-on-transfer token would credit
more than was received, re-introducing an F-2-style backing gap.
- **Fix:** measure `balanceOf(this)` before/after and credit the delta (the `safeTransferIn` pattern).
  Acceptable for the MVP scope (target assets are standard ERC-20s like USDC/WETH).

### F-4 — `monthlyPayout` not validated (`> 0`) (INFORMATIONAL)
`setEndowment` accepts `monthlyPayout == 0`. `collectMonthly` would then consume a 30-day cadence
window paying `0` (it only reverts when the buffer is empty). Harmless but wasteful; consider
rejecting a zero payout.

### F-5 — `claim` leaves `beneficiary` pointing at the new owner (INFORMATIONAL — mitigated)
After `claim`, `e.beneficiary` still equals the claimer (now the owner). Previously there was no way
to fix this, so succession was impossible. Mitigated by the new `setBeneficiary(positionKey, …)`
(owner-gated), which lets an heir name the next heir. A self-claim before re-designating is a no-op
(owner is already the caller).

## Risk score (per the v4-security-foundations rubric)

| Category | Points | Rationale |
|---|---|---|
| Permissions | ~4 / 14 | afterAddLiquidity (LOW) + afterRemoveLiquidity (LOW) + afterSwap (MEDIUM); no return-delta flags |
| External calls | 2 / 5 | ERC-20 `safeTransfer` / `safeTransferFrom` only |
| State complexity | 3 / 5 | One mapping of packed structs; O(1) access |
| Upgrade mechanism | 0 / 5 | Immutable, no admin |
| Token handling | 2 / 4 | Standard ERC-20 assumed; no fee-on-transfer support (F-3) |
| **Total** | **~11 / 33** | **Medium** → professional audit recommended before mainnet |

## Recommendations (priority order)
1. **v1.5 real fee capture** (closes F-2 and F-1's accrual path) — the single most important change.
2. **Invariant test:** per-currency `sum(buffers) ≤ hook balance`. (Will fail until #1 lands — which
   is precisely the point; it encodes the MVP boundary.)
3. **Fuzz** `setEndowment` / `collectMonthly` / `claim` timing and amounts.
4. Adopt the `safeTransferIn` balance-delta pattern in `deposit` (F-3).
5. Reject `monthlyPayout == 0` (F-4).
