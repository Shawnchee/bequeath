# Bequeath — Product Requirements Doc

**Author**: Shawn
**Cohort**: UHI9
**Track**: Impermanent Loss & Yield Systems
**Last updated**: May 24, 2026
**Status**: Draft, day-zero

---

## 1. Problem

DeFi yield has two unsolved problems for serious users:

**Problem A — Lumpy, unpredictable income**. LP fees accrue in proportion to swap volume, which is volatile. A pool earning "20% APR" might generate 80% one week, 0% the next. This makes LP yield useless for retirees, DAO operating budgets, treasuries, or anyone who needs predictable cash flow. The traditional finance answer is the **annuity** — a smoothed, predictable payout backed by a principal. Nothing like this exists native to AMM pools.

**Problem B — Yield dies with the owner**. Chainalysis estimates ~$140B in BTC alone is permanently lost, much from owners who died or were incapacitated without succession plans. Even for owners who *did* plan, their LP positions are frozen NFTs — heirs receive a static blob, not a living income stream. Existing inheritance protocols (Casa, Vault12, Sarcophagus) operate at the wallet/file layer and don't preserve the yield curve.

## 2. Goal

Build a Uniswap v4 hook that combines both:

- **Fee-smoothing annuity**: LPs designate a target monthly payout. The hook accumulates fees into a buffer and releases the configured payout on a fixed schedule, smoothing yield into a pension.
- **Native inheritance**: LPs designate a beneficiary and a heartbeat interval. Any withdrawal, swap, or manual ping refreshes the heartbeat. If the owner goes silent past the interval, the beneficiary inherits the annuity stream.

Together, this is the **first onchain endowment**: a position that pays out predictably and survives generations.

## 3. Non-Goals

- **No legal estate wrapper** — Bequeath is the onchain mechanism, not legal advice.
- **No multi-asset wallet inheritance** — only Bequeath-enabled LP positions are covered.
- **No oracle dependency** — we use onchain inactivity, not external death certificates.
- **No upgrade path in v1** — the hook will be immutable.
- **No external yield sources** — annuity is funded purely from the pool's own swap fees.

## 4. Users & Use Cases

| User | Use case |
|---|---|
| Retiree | Provides liquidity to ETH/USDC. Sets a $1,000/month annuity. Designates spouse as beneficiary. Lives off the smoothed yield. |
| DAO treasury | Provides liquidity from idle treasury. Configures predictable monthly operational budget. Beneficiary = successor multisig. |
| Family office | Manages multi-generational LP exposure. Annuity pays out to current generation; chained beneficiaries handle succession. |
| Solo LP | Wants predictable income from a long-term position; wants a friend to inherit it if anything happens. |

## 5. Scoring Self-Check (against UHI rubric)

| Criterion | Weight | Bequeath rating | Reasoning |
|---|---|---|---|
| Original Idea | 30% | **5/5** | No existing hook combines fee-smoothing with inheritance. Both pieces individually are underbuilt (annuity not implemented anywhere; inheritance done at wallet level only). |
| Unique Execution | 25% | **5/5** | Two-in-one architecture is novel. Annuity buffer + heartbeat in a single hook is a unique combination. |
| Impact | 20% | **5/5** | Annuity addresses the $trillion pension market's DeFi gap. Inheritance addresses $140B+ lost crypto. Both have non-crypto resonance. |
| Functionality | 15% | **4/5** | Doable in 40 hrs with simplifications. Push to 5/5 with full PoolManager integration in M3. |
| Presentation Pitch | 10% | **5/5** | "The first DeFi pension that outlives you" is unforgettable. Two-graph demo (lumpy vs. smoothed) is visceral. |
| **Weighted** | | **~4.85 / 5.0** | |

## 6. Architecture (MVP)

```
                       ┌──────────────────────┐
   User swaps in pool  │   PoolManager        │
   ───────────────────► │   (Uniswap v4 core)  │
                       └──────────┬───────────┘
                                  │ calls back via afterSwap
                                  ▼
                       ┌──────────────────────────────────┐
                       │   Bequeath (Hook)                │
                       │                                  │
                       │   ANNUITY                        │
                       │   • afterSwap → accumulate to    │
                       │     position's buffer            │
                       │   • collectMonthly() →           │
                       │     release smoothed payout      │
                       │     (gated by 30-day cadence)    │
                       │                                  │
                       │   INHERITANCE                    │
                       │   • afterAddLiquidity / afterSwap│
                       │     refresh heartbeat            │
                       │   • setBeneficiary()             │
                       │   • ping()                       │
                       │   • claim() — beneficiary takes  │
                       │     over annuity after interval  │
                       └──────────────────────────────────┘
```

### State

Per position (keyed by `(owner, poolId, tickLower, tickUpper, salt)`):

```solidity
struct Endowment {
  address owner;
  address beneficiary;

  // Annuity
  uint128 buffer;             // accumulated fees in hook's keeping
  uint128 monthlyPayout;      // target steady payout per 30 days
  uint64  lastPayoutTime;     // last successful withdrawal

  // Inheritance
  uint64  heartbeatInterval;  // seconds of inactivity before claim is allowed
  uint64  lastHeartbeat;      // unix timestamp of last activity / ping
  bool    active;
}
mapping(bytes32 positionKey => Endowment) public endowments;
```

### Flow

1. User adds liquidity to a pool with Bequeath attached. Calls `setEndowment(positionKey, monthlyPayout, beneficiary, heartbeatInterval)`.
2. As swaps happen, `afterSwap` accumulates a configurable cut (e.g., 1% of swap fee value) into the position's `buffer`.
3. Owner can call `collectMonthly(positionKey)` once per 30-day window — receives `min(monthlyPayout, buffer)`. Any excess stays in the buffer for future shortfall periods.
4. Every withdrawal and pool activity refreshes `lastHeartbeat`. Owner can also `ping()` manually.
5. If `block.timestamp - lastHeartbeat > heartbeatInterval`, beneficiary calls `claim()` — `owner` field updates to beneficiary, who can now collect the annuity stream.

## 7. Scope by Milestone

### M1 — Day 1–7 (Progress Update 1, due Jun 1)

- Foundry project compiles with v4-core + OpenZeppelin uniswap-hooks
- `Bequeath.sol` skeleton: state + `setEndowment` + `ping` + `claim`
- `afterAddLiquidity` refreshes heartbeat
- 4 registry tests passing
- Submit Progress Update 1

### M2 — Day 8–14 (Progress Update 2, due Jun 8)

- `afterSwap` accumulates to buffer (MVP: take fixed % of input amount as "fee cut")
- `collectMonthly()` payout with 30-day cadence guard
- Test: warp 30+ days, collect, assert smoothed payout
- Test: insufficient buffer → reduced payout
- Test: post-interval claim transfers annuity to beneficiary
- README first draft
- Submit Progress Update 2

### M3 — Day 15–18 (Final submission, due Jun 11)

- Polish: events, custom errors, NatSpec
- Edge cases: zero-address checks, double-claim, claim after revoke
- Record 5-min Loom demo (two-graph slide → live test run → "why it matters")
- Final README with architecture diagram, explicit theme alignment, "no partner integrations" line
- Submit final via Tally form

## 8. Out of scope (v1.5+ ideas)

- **Actual hookDelta-based fee capture** — v1 uses voluntary `deposit()` to seed the buffer; v1.5 wires `afterSwap` returning a `BalanceDelta` that captures real swap fees
- **Underlying position transfer** — v1 only updates the Bequeath registry; v1.5 transfers the PositionManager NFT too
- **Multi-beneficiary splits** — 50% spouse, 50% charity
- **Chained beneficiaries** — heir → heir → heir
- **Variable monthly payout** — based on actual yield realized (escalator clauses)
- **EAS attestation gate** — beneficiary must prove identity before claim
- **Frontend** — testing-only for hackathon

## 9. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Real fee capture via afterSwap deltas is complex in v4 | MVP uses voluntary `deposit()` to seed the buffer + comments showing how production would use BalanceDelta. Tests don't depend on real fee capture. |
| Position-key construction differs from PoolManager's internal keying | Use the same `keccak256(owner, poolId, tickLower, tickUpper, salt)` formula PoolManager uses internally |
| `sender` in hook callbacks is a router | MVP: assume direct PoolManager interaction. V1.5: parse `hookData` for the true owner |
| Beneficiary forgets to claim, another wallet takes over | `claim()` is permissioned to `endowments[pk].beneficiary` only |
| Hook bricks user funds (Cork-style $11M hack) | Make hook **immutable**, no proxy. All beneficiary-affecting state changes go through revertable paths. Run through Hacken/Dedaub checklist. |
| Owner on vacation, accidentally claimed | 90-day default interval. Owner can extend anytime. `claim()` is irreversible — communicate clearly in UX. |
| Annuity payout drains buffer faster than fees accrue | `collectMonthly()` returns `min(monthlyPayout, buffer)` — never overdraws. Owner sees reduced payout and can lower target. |

## 10. Demo Plan (the 5-minute video)

| 0:00–0:30 | **The problem** — two side-by-side line graphs: (left) lumpy weekly LP fees, (right) flat monthly annuity. Voiceover: "DeFi yield is unusable for retirees, DAOs, anyone who needs predictable cash flow. And when the owner dies, all of it dies with them." Cite $140B Chainalysis stat. |
| 0:30–1:30 | **The hook** — animated slide showing position lifecycle: swaps fill the buffer; owner pulls smoothed monthly payouts; heartbeat refreshes; beneficiary inherits. |
| 1:30–3:30 | **Live test run** — `forge test -vv` showing: (1) setEndowment, (2) several swaps accumulating buffer, (3) `vm.warp` 30 days, owner collects smoothed payout, (4) `vm.warp` 91 days, beneficiary successfully claims, (5) beneficiary now collects payouts. |
| 3:30–4:30 | **Why this matters** — annuity = TradFi pension industry's first onchain product; inheritance = first hook to preserve yield generationally. Sticky liquidity narrative for protocols. Family office / RIA partnerships. |
| 4:30–5:00 | **What's next** — real fee capture via hookDelta, full position transfer, multi-beneficiary, frontend. |

Hard rule: real voice, no AI narration.

## 11. Open Questions

- Match PoolManager's internal position keying exactly? → confirm against `Pool.sol` Position library
- Best way to capture real swap fees in v4? → study `afterSwap` BalanceDelta returns, lean on OpenZeppelin uniswap-hooks examples
- Should `ping()` be permissioned to owner only, or open? → owner-only for v1; open could be a feature flag in v1.5 ("trusted ping" for caregivers)
- Should annuity payout be in token0, token1, or both proportionally? → decide based on what the buffer accrues; likely both
