# ReactiveGuard — a stop-loss that fires itself

**Reactive Omni Buildathon · Track: Every Second Counts**

A reactive stop-loss / take-profit guard for DEX positions. You set two price
levels once; from then on, a reactive contract on Reactive Network watches the
price feed for you, and the moment a level is breached it sells the position
on the destination chain by itself — in seconds, with no keeper bot, no
server, and no transaction from you.

Every part of the loop runs on testnet and costs nothing but free faucet
tokens: origin and destination on **Base Sepolia**, the reactive contract on
**Reactive Lasna**.

---

## Submission data

| Item | Value |
|---|---|
| Public repo | https://github.com/maungzy86/reactive-guard |
| Demo video (< 3 min) | _TODO: link_ |
| PriceFeed (Base Sepolia) | _TODO: address_ |
| MockDex (Base Sepolia) | _TODO: address_ |
| StopLossVault (Base Sepolia) | _TODO: address_ |
| ReactiveGuard (Lasna) | _TODO: address_ |
| Origin event tx (`updatePrice`) | _TODO: tx hash_ |
| Reactive tx (Lasna, `react()` + `CallbackRequest`) | _TODO: tx hash_ |
| Callback tx (Base Sepolia, `executeExit`) | _TODO: tx hash_ |
| Measured full-loop latency | _TODO: seconds (vault's on-chain `loopLatencySeconds`)_ |

## The problem

Stop-losses on-chain don't really exist for ordinary users. A DEX position
has no native "sell if price ≤ X" order: you either watch the chart yourself,
hand your keys to an off-chain keeper bot (which can be down, hacked, or
rug-prone), or pay for a centralized service. Every one of those fails
exactly when it matters — during a fast crash, at 3 a.m., in seconds.

## The solution

Reactive contracts invert the model: instead of polling the chain from
outside, the contract subscribes to the chain's events from inside the
network and acts on its own. ReactiveGuard is three contracts and one event:

```
Base Sepolia                     Lasna (Reactive)                 Base Sepolia
─────────────                    ─────────────────                ─────────────
PriceFeed                        ReactiveGuard                    StopLossVault
  │ updatePrice()                  │ subscribes to                  │ holds users'
  │ emits PriceUpdated ──────────▶ │ PriceUpdated events            │ TOKEN deposits
  │                                │ price ≤ stop-loss or           │
  │                                │ price ≥ take-profit  ────────▶ │ executeExit():
  │                                │ requestCallbackV_1_0           │ sells everything
  │                                │                                │ on MockDex
  │                                │                                ▼
  │                                │                             users withdraw
  │                                │                             QUOTE proceeds
```

1. **PriceFeed** (origin) — a demo price oracle. `updatePrice()` emits
   `PriceUpdated(price, timestamp)`. (In production this role belongs to a
   real DEX pair or oracle; a permissionless setter keeps the demo
   reproducible by anyone.)
2. **ReactiveGuard** (reactive, Lasna) — subscribes to `PriceUpdated` in its
   constructor via the system contract at
   `0x8888888888888888888888888888888888888888`. On every event it compares
   the price against its stop-loss / take-profit thresholds. On a breach it
   latches one-shot, unsubscribes (so it stops being billed), and requests a
   callback with `SYSTEM.requestCallbackV_1_0(...)`.
3. **StopLossVault** (destination / callback) — holds the guarded position.
   Its `executeExit` can only be reached through the Base Sepolia callback
   proxy (`0x476F44b11F5C942c58f4c8E3d0300E5710743585`) and only for callbacks
   originating from ReactiveGuard — the official dual-guard pattern,
   `onlyServiceProvider` + `onlyCallbackSender`. It swaps the vault's entire
   TOKEN balance to QUOTE on **MockDex** in the same transaction, then users
   withdraw their pro-rata proceeds with `withdrawQuote()`.

### Why "every second counts" is measurable here

The origin event carries its block timestamp through the whole loop, and the
vault records `loopLatencySeconds = execution timestamp − origin timestamp`
on-chain in the exit transaction. The demo's headline number is not a claim —
it's a storage slot anyone can read with one `cast call`. (Base Sepolia
produces ~200 ms blocks since the Denim upgrade, so timestamps, not block
counts, are the honest measure.)

## Security notes

- `react()` is guarded by `onlySystem` — a fabricated log record from any
  other caller reverts with `NotAuthorized`.
- The callback's first payload argument is reserved: the network overwrites
  it with the requesting reactive contract's address, and the vault checks it
  against its immutable `_CALLBACK_SENDER`. A wrong sender at deployment is
  unrecoverable by design (redeploy), so it can't be silently swapped later.
- The guard is one-shot per arming and unsubscribes when it fires, so a burst
  of price updates can never trigger a double exit.
- Both contracts follow the official economy model: the guard pays for its
  reactive transactions in lREACT, the vault pays for callbacks in Base
  Sepolia ETH, and both expose `coverDebt()`.

## Repository layout

```
src/
  origin/PriceFeed.sol          origin event source (Base Sepolia)
  reactive/ReactiveGuard.sol    the reactive contract (Lasna)
  destination/StopLossVault.sol callback contract / guarded vault (Base Sepolia)
  destination/MockDex.sol       fixed-price swap venue used by the exit
  mocks/MockERC20.sol           demo TOKEN / QUOTE
script/                         the four deployment steps, in order
test/                           20 Foundry tests incl. a full-loop simulation
DEPLOY.md                       step-by-step testnet deployment runbook
```

## Try it locally (no chain, no funds)

```bash
forge build
forge test        # 20 tests, including test_FullStopLossLoop
```

The end-to-end test simulates the entire cross-chain loop leg by leg with a
mock system contract etched at the real system address and a mock callback
proxy: price crash → log delivery → callback request → proxy delivery →
vault exit → user payout, asserting amounts, the one-shot latch, and the
recorded latency at every step.

## Deploy it (free, testnet)

See **DEPLOY.md** — faucet steps for Base Sepolia ETH and lREACT (the
official exchange contract: send Base Sepolia ETH, receive 100× lREACT on
Lasna), the four deployment commands in the official order, Sourcify
verification, the demo script, and troubleshooting (debt, `CallbackFailure`,
recipient setup).

## Built with

Solidity 0.8.29 · Foundry · the official
[`reactive-lib-omni`](https://github.com/Reactive-Network/reactive-lib-omni)
(`AbstractReactive` / `AbstractCallback`) · docs at
https://dev.reactive.network

Contracts in `src/` are MIT-licensed; the vendored library under `lib/`
keeps its upstream license.
