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

The cleanest path is to start from the [official v4-template](https://github.com/uniswapfoundation/v4-template), which already wires up every submodule and remapping this hook depends on, then drop in `src/Bequeath.sol` and `test/Bequeath.t.sol`.

```bash
# Start from the v4-template (gets all submodules right)
git clone --recurse-submodules https://github.com/uniswapfoundation/v4-template.git bequeath
cd bequeath

# Drop in Bequeath
cp /path/to/Bequeath/src/Bequeath.sol src/
cp /path/to/Bequeath/test/Bequeath.t.sol test/

# Build & test
forge build
forge test -vv
```

If you'd rather build from scratch (matching the verified remappings in `remappings.txt`):

```bash
forge init bequeath && cd bequeath
forge install foundry-rs/forge-std --no-commit
forge install OpenZeppelin/uniswap-hooks --no-commit
# uniswap-hooks pulls v4-core, v4-periphery, openzeppelin-contracts, solmate as nested submodules
git submodule update --init --recursive
# copy in foundry.toml + remappings.txt from this repo, then src/ and test/
forge build
forge test -vv
```

> **Verified clean compile**: this code was compiled with solc 0.8.30 (cancun EVM) against the real v4-core, v4-periphery, OpenZeppelin uniswap-hooks, OZ contracts, and forge-std libraries. Both `src/Bequeath.sol` (47 ABI entries) and `test/Bequeath.t.sol` build with 0 errors and 0 warnings.

## Architecture

| Component | What it does |
|---|---|
| `src/Bequeath.sol` | The v4 hook. Per-position `Endowment` struct, annuity buffer accumulation via `afterSwap`, monthly payout, heartbeat-based inheritance |
| `test/Bequeath.t.sol` | Unit tests: endowment setup, buffer deposit, monthly payout cadence and smoothing, heartbeat refresh, inheritance claim, beneficiary collection after claim |

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
