# DEPLOY.md — ReactiveGuard deployment runbook (testnet only)

> **STATUS: NOT DEPLOYED YET.** This runbook is prepared ahead of time.
> Deployment happens only after a separate pre-deployment check.
> Everything here is **testnet**: Base Sepolia + Reactive Lasna. No mainnet,
> no real funds. Use a **fresh, testnet-only private key** — never a key that
> holds mainnet assets.

## What gets deployed, where

| Step | Chain | Contract(s) | Paid in |
|---|---|---|---|
| 1 | Base Sepolia (84532) | `MockERC20` TOKEN, `MockERC20` QUOTE, `PriceFeed`, `MockDex` | Base Sepolia ETH |
| 2 | Reactive Lasna (5318007) | `ReactiveGuard` (funded at deployment) | lREACT |
| 3 | Base Sepolia (84532) | `StopLossVault` (funded at deployment) | Base Sepolia ETH |
| 4 | Reactive Lasna (5318007) | `ReactiveGuard.setRecipient(vault)` | lREACT |

The order matters (official docs, "Deployment Order"): the vault immutably
stores the guard's address, and the guard learns the vault's address through
the step-4 setter.

### Network parameters (from the official docs)

| | Base Sepolia | Reactive Lasna |
|---|---|---|
| Chain ID | 84532 | 5318007 |
| RPC | `https://sepolia.base.org` | `https://lasna-rpc.rnk.dev/` |
| Explorer | https://sepolia.basescan.org | https://lasna.reactscan.net |
| Native token | ETH (testnet) | lREACT |

Fixed protocol addresses:

- Reactive system contract (Lasna): `0x8888888888888888888888888888888888888888`
- Base Sepolia callback proxy: `0x476F44b11F5C942c58f4c8E3d0300E5710743585`
- Lasna faucet contract **on Base Sepolia**: `0x2afaFD298b23b62760711756088F75B7409f5967`

## Step 0 — Prerequisites

```bash
curl -L https://foundry.paradigm.xyz | bash   # then: foundryup
git clone <THIS_REPO_URL> reactive-omni-app
cd reactive-omni-app
forge build && forge test                     # expect: 20 passed
```

Create `.env` (never commit it — it is in `.gitignore`):

```bash
# A fresh TESTNET-ONLY key. It will hold only worthless testnet tokens.
PRIVATE_KEY=0x<testnet-only-key>
BASE_SEPOLIA_RPC=https://sepolia.base.org
LASNA_RPC=https://lasna-rpc.rnk.dev/
```

## Step 1 — Fund the deployer (all free)

### 1a. Base Sepolia ETH

Get test ETH from any Base Sepolia faucet, e.g.:

- Alchemy: https://www.alchemy.com/faucets/base-sepolia
- QuickNode: https://faucet.quicknode.com/base/sepolia
- Coinbase CDP faucet: https://portal.cdp.coinbase.com/products/faucet

You need roughly **0.15 ETH** total: ~0.05 for deployments, 0.05 to fund the
vault, and 0.1 to exchange for lREACT in step 1b.

### 1b. lREACT for Lasna (official faucet exchange)

The official way to get lREACT is to send Base Sepolia ETH to the faucet
contract on Base Sepolia — **1 ETH → 100 lREACT**, credited to the *same
address* on Lasna. Do not send more than 5 ETH per transaction.

```bash
source .env
cast send 0x2afaFD298b23b62760711756088F75B7409f5967 \
  --rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY \
  "request(address)" $(cast wallet address --private-key $PRIVATE_KEY) \
  --value 0.1ether        # → 10 lREACT on Lasna
```

Verify the lREACT arrived (same address, Lasna chain):

```bash
cast balance --rpc-url $LASNA_RPC $(cast wallet address --private-key $PRIVATE_KEY)
```

## Step 2 — Deploy the origin + market stack (Base Sepolia)

```bash
source .env
forge script script/DeployOrigin.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast
```

Record the four printed addresses into `.env`:

```bash
TOKEN=0x...
QUOTE=0x...
PRICE_FEED=0x...
DEX=0x...
```

Defaults: initial price 2,000 QUOTE/TOKEN; the DEX is funded with
10,000,000 QUOTE; the deployer receives 10,000 demo TOKEN.

## Step 3 — Deploy ReactiveGuard (Lasna)

Funded with 5 lREACT at deployment (it pays for its own reactive
transactions). Threshold defaults: stop-loss 1,500 / take-profit 3,000
(QUOTE per TOKEN, 1e18-scaled; override with `STOP_LOSS` / `TAKE_PROFIT`).

```bash
source .env
PRICE_FEED=$PRICE_FEED forge script script/DeployReactive.s.sol \
  --rpc-url $LASNA_RPC --private-key $PRIVATE_KEY --broadcast
```

Record: `REACTIVE_GUARD=0x...`

## Step 4 — Deploy StopLossVault (Base Sepolia)

Funded with 0.05 ETH at deployment (the callback proxy bills the vault, in
ETH, for callback execution).

```bash
source .env
REACTIVE_GUARD=$REACTIVE_GUARD TOKEN=$TOKEN QUOTE=$QUOTE DEX=$DEX \
forge script script/DeployDestination.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast
```

Record: `VAULT=0x...`

## Step 5 — Point the guard at the vault (Lasna)

```bash
source .env
REACTIVE_GUARD=$REACTIVE_GUARD VAULT=$VAULT \
forge script script/SetRecipient.s.sol \
  --rpc-url $LASNA_RPC --private-key $PRIVATE_KEY --broadcast
```

Sanity checks:

```bash
cast call --rpc-url $LASNA_RPC $REACTIVE_GUARD "recipient()(address)"   # == $VAULT
cast balance --rpc-url $LASNA_RPC $REACTIVE_GUARD                      # > 0 lREACT
cast balance --rpc-url $BASE_SEPOLIA_RPC $VAULT                        # > 0 ETH
```

## Step 6 — Verify the contracts (Sourcify, per the official docs)

```bash
forge verify-contract --verifier sourcify --chain-id 84532 $PRICE_FEED PriceFeed
forge verify-contract --verifier sourcify --chain-id 84532 $VAULT StopLossVault
forge verify-contract --verifier sourcify --chain-id 5318007 $REACTIVE_GUARD ReactiveGuard
```

## Step 7 — Run the demo (the full reactive loop)

```bash
source .env
ME=$(cast wallet address --private-key $PRIVATE_KEY)

# 1) Take a guarded position: deposit 50 TOKEN into the vault.
cast send --rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY $TOKEN "approve(address,uint256)" $VAULT 50000000000000000000
cast send --rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY $VAULT "deposit(uint256)" 50000000000000000000

# 2) Crash the price through the 1,500 stop-loss. This single transaction is
#    the ONLY human action in the whole exit.
cast send --rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY $PRICE_FEED "updatePrice(uint256)" 1450000000000000000000
```

Then watch, in order:

1. **Base Sepolia** (https://sepolia.basescan.org): the `updatePrice` tx —
   the origin event. Note its timestamp.
2. **Lasna** (https://lasna.reactscan.net): a reactive transaction to
   `ReactiveGuard` fires within seconds; the system contract emits
   `CallbackRequest` for chain 84532 → the vault.
3. **Base Sepolia**: the callback proxy calls `StopLossVault.executeExit`;
   the vault emits `ExitExecuted` and the TOKEN→QUOTE swap happens on
   `MockDex` in the same transaction.

Read the measured end-to-end latency (destination execution timestamp minus
origin event timestamp, recorded on-chain by the vault):

```bash
cast call --rpc-url $BASE_SEPOLIA_RPC $VAULT "loopLatencySeconds()(uint256)"
cast call --rpc-url $BASE_SEPOLIA_RPC $VAULT "totalQuoteOut()(uint256)"
```

Finally, withdraw the proceeds:

```bash
cast send --rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY $VAULT "withdrawQuote()"
```

Record for the submission: origin tx hash, Lasna reactive tx hash, callback
tx hash, and the latency number. (Base Sepolia blocks are ~200 ms since the
Denim upgrade — timestamps, not block counts, are the right latency measure.)

To run the demo again, re-arm the guard with fresh thresholds:

```bash
cast send --rpc-url $LASNA_RPC --private-key $PRIVATE_KEY $REACTIVE_GUARD \
  "rearm(uint256,uint256)" 1500000000000000000000 3000000000000000000000
```

(And deposit again — the previous position already exited.)

## Expected transaction flow

```
Base Sepolia                     Lasna (Reactive)                 Base Sepolia
─────────────                    ─────────────────                ─────────────
updatePrice(1450e18)
  └─ PriceUpdated event ───────▶ ReactiveGuard.react()
                                   ├─ price ≤ stop-loss → trigger
                                   ├─ unsubscribe (one-shot)
                                   └─ SYSTEM.requestCallbackV_1_0 ─▶ Callback proxy
                                                                        └─ StopLossVault.executeExit()
                                                                             ├─ MockDex swap TOKEN→QUOTE
                                                                             └─ ExitExecuted (latency recorded)
User: withdrawQuote() ◀────────────────────────────────────────────── QUOTE proceeds
```

## Troubleshooting

- **Nothing happens after `updatePrice`.** Check the guard is not in debt and
  holds lREACT: debt accrues if the balance ran dry, and a contract in debt
  receives nothing. Top it up (send lREACT to the guard address) and call
  `coverDebt()`. Also confirm step 5 ran (`recipient()` == vault) — before
  that, the guard deliberately requests no callbacks.
- **`CallbackFailure` on the destination.** The callback ran out of gas or
  reverted; the vault is still billed for the attempt. The gas limit is set
  on the reactive side (`CALLBACK_GAS_LIMIT` in `ReactiveGuard`).
- **Vault stopped receiving callbacks.** Same debt rule, on the destination
  side: fund the vault with ETH and call its `coverDebt()`.
- **Wrong vault authorized.** `StopLossVault._CALLBACK_SENDER` is immutable.
  If step 4 was given the wrong guard address, redeploy the vault — there is
  no setter, by design.
