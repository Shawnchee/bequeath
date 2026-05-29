# Bequeath

> **The first DeFi pension that outlives you.**
> A Uniswap v4 hook that converts lumpy LP fees into a predictable monthly annuity payout, with native inheritance built in.

UHI9 Hookathon track: **Impermanent Loss & Yield Systems**

---

## The problem

DeFi yield has two unsolved problems:

1. **Lumpy income** — LP fees are proportional to swap volume, which is volatile. A "20% APR" pool might return 80% one week and 0% the next. Useless for retirees, DAOs, or anyone needing predictable cash flow.
2. **Yield dies with the owner** — Chainalysis estimates **~$140B in BTC** is permanently lost, much from deceased or incapacitated owners. Even with succession plans, heirs receive a static blob of assets, not a living income stream.

## The hook

Bequeath solves both at the protocol layer:

```
       ┌──────────────────────────────────────────────┐
       │  ANNUITY                                     │
       │  swaps → afterSwap accrues to buffer         │
       │  owner.collectMonthly() → smoothed payout    │
       │  (capped by buffer, gated to once / 30 days) │
       └──────────────────────────────────────────────┘
                              +
       ┌──────────────────────────────────────────────┐
       │  INHERITANCE                                 │
       │  owner activity → heartbeat refresh          │
       │  owner.ping() → manual refresh               │
       │  if inactive > interval → beneficiary.claim()│
       │  beneficiary becomes new owner, keeps yield  │
       └──────────────────────────────────────────────┘
```

## How to run

Prereqs: [Foundry](https://book.getfoundry.sh/getting-started/installation).

This repo wires its own dependencies as git submodules — forge-std and OpenZeppelin `uniswap-hooks`
(which pulls v4-core, v4-periphery, openzeppelin-contracts, and solmate). Clone with submodules and test:

```bash
git clone --recurse-submodules <this-repo-url> bequeath
cd bequeath
forge test -vv
```

Already cloned without `--recurse-submodules`? Pull them and test:

```bash
git submodule update --init --recursive
forge test -vv
```

Run the generational-saga demo on its own — this is the shoot script for the video:

```bash
forge test --match-test test_demo_pensionThatOutlivesYou -vvv
```

> **Verified locally**: builds with **solc 0.8.26** (cancun EVM — the version v4-core pins) against
> the real v4-core, v4-periphery, OpenZeppelin uniswap-hooks, OZ contracts, and forge-std.
> **22 tests pass, 0 failed**: 18 API unit tests, 3 live-`PoolManager` integration tests, and the
> 1 generational-saga demo. See [SECURITY.md](SECURITY.md) for the threat model and known MVP boundaries.

## Architecture

| Component | What it does |
|---|---|
| `src/Bequeath.sol` | The v4 hook. Per-position `Endowment` struct, annuity buffer accrual via `afterSwap`, monthly payout, heartbeat-based inheritance, `setBeneficiary` succession |
| `test/Bequeath.t.sol` | API unit tests: endowment setup, buffer deposit, monthly payout cadence and smoothing, heartbeat refresh, inheritance claim, beneficiary collection after claim |
| `test/BequeathIntegration.t.sol` | Live-`PoolManager` integration: real swaps accrue the buffer via `afterSwap`, real liquidity events refresh the heartbeat, swaps never brick the pool |
| `test/BequeathDemo.t.sol` | The demo shoot script: one position across three generations (retiree → spouse → daughter) with narrated `console2` output |
| `SECURITY.md` | Self-audit against the v4 hook threat model — checklist, findings, risk score, MVP boundaries |

### Hook permissions used

- `afterAddLiquidity` — registers payout currency, refreshes heartbeat
- `afterSwap` — accumulates annuity buffer, refreshes heartbeat
- `afterRemoveLiquidity` — refreshes heartbeat (owner pulled liquidity → still alive)

### Position keying

Positions are identified by `keccak256(owner, poolId, tickLower, tickUpper, salt)`, matching v4's internal scheme so beneficiaries can target exactly one position.

### Key constants

- `PAYOUT_PERIOD = 30 days` — owners can collect at most once per month
- `DEFAULT_INTERVAL = 90 days` — default heartbeat
- `MIN_INTERVAL = 1 days` — floor on configurable heartbeat (prevents accidental triggers)
- `ANNUITY_CUT_BPS = 100` — 1% of swap input flows to the position's annuity buffer (MVP; v1.5 replaces with real BalanceDelta fee capture)

## Partner integrations

**None.** This submission competes for the Impermanent Loss & Yield Systems track without external sponsor integrations. The hook is purely fee-smoothing + inheritance, using only Uniswap v4 primitives and OpenZeppelin's uniswap-hooks library.

## Roadmap (post-hackathon)

- **Real fee capture** via `afterSwap` BalanceDelta returns (replaces MVP's voluntary `deposit()`)
- **Underlying position transfer** — claim also rekeys the PositionManager NFT
- **Multi-beneficiary splits** — 50% spouse, 50% charity
- **Chained beneficiaries** — heir → heir → heir
- **Variable payouts** — escalator/de-escalator clauses based on realized yield
- **EAS attestation gate** — beneficiary must prove identity before claim
- **Frontend** — current-month payout dashboard, time-until-claim countdown

## Demo video outline

1. **(0:00–0:30) Problem** — two graphs side-by-side: lumpy weekly LP fees vs. flat monthly annuity. Chainalysis $140B lost-crypto stat.
2. **(0:30–1:30) Hook** — animated lifecycle: swaps fill buffer, owner collects, heartbeat refreshes, beneficiary inherits.
3. **(1:30–3:30) Live test run** — `forge test -vv` showing setup → deposit → monthly payout → inheritance claim → beneficiary collects.
4. **(3:30–4:30) Why this matters** — pension industry's first onchain product; first hook to preserve generational yield.
5. **(4:30–5:00) Roadmap** — real fee capture, multi-beneficiary, frontend.

Hard rule: real voice, no AI narration.

## License

MIT
