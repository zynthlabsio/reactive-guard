# DEPLOY-RESULTS.md — ReactiveGuard live testnet deployment

Deployed 2026-11-19 (UTC) following `DEPLOY.md`, with two budget adjustments
for the actual deployer balance (0.1101 Base Sepolia ETH instead of ~0.15):
the lREACT exchange used **0.055 ETH → 5.5 lREACT** (guard funded with
5 lREACT), and the vault was funded with the runbook's 0.05 ETH.

Deployer: `0x61F29c91d9346221E3dF7fCb3F5b9d41F61Ea9A3` (testnet only)

## Contracts

| Contract | Chain | Address |
|---|---|---|
| MockERC20 TOKEN | Base Sepolia (84532) | `0xf546cd1975f2aa6fc40dded0b5a31e701f2251f6` |
| MockERC20 QUOTE | Base Sepolia (84532) | `0x786C83cC3cFF6d164Ed8Fc14355f8E968e7Ba93F` |
| PriceFeed | Base Sepolia (84532) | `0xaC4Ea4207934a058422FF592350C20155Cd1Ca9B` |
| MockDex | Base Sepolia (84532) | `0x21f855e233624f10d9c8f2Ed49E4Dc08F8f059Ff` |
| ReactiveGuard | Reactive Lasna (5318007) | `0xbCB5964894Fe6CcFa26f400130DC32dE5C76bD71` |
| StopLossVault | Base Sepolia (84532) | `0xA0d771B200606ee9611bdEd59Dec6a455C44d95d` |

Thresholds: stop-loss 1,500 QUOTE/TOKEN, take-profit 3,000 QUOTE/TOKEN.
Initial price: 2,000 QUOTE/TOKEN. DEX funded with 10,000,000 QUOTE;
deployer received 10,000 demo TOKEN.

## Transactions

| Step | Tx hash |
|---|---|
| 1b. lREACT exchange (0.055 ETH → 5.5 lREACT, Base Sepolia) | `0xd1b47c2fe6e099fda4e3e558ab783dd3e28fad2d15be8df2523a9bf4e54b9a34` |
| 2. Deploy TOKEN | `0xaec72d8f27010dd792cab5646275248ab969a9b62267e11a132f72622578f55f` |
| 2. Deploy QUOTE | `0x03ad2d7578f9a1628656512c0e66266f0db66cc3a525bd6e7aa56fef87a4b834` |
| 2. Deploy PriceFeed | `0x3816cd31ebd15df893dd2184e375e80c3476e0878c4b0579f140d4d908468c27` |
| 2. Deploy MockDex | `0xe6f18e17c810596480b149983e67b43acc525bff4a429cba2c4c683baeccf22e` |
| 3. Deploy ReactiveGuard (Lasna, funded 5 lREACT) | `0x75efa90db6daee91c5bfc68701f05124e05ba92eec412e38224bbb168c57ee57` |
| 4. Deploy StopLossVault (funded 0.05 ETH) | `0x2251b62d492b3337255dd07a5ed9551a27f38de9a99a54ddddb0c241dd3a0288` |
| 5. SetRecipient (Lasna) | `0x15be40d06aedb350d0d28f28ebfd82e74b7edd455a2b24436a580069db50bfe2` |
| 7. Demo: approve 50 TOKEN | `0xfbbd0b2b1efa944c593cee4bb6fc4bf328aeb95c4f2b974c2adec925ad9ba132` |
| 7. Demo: deposit 50 TOKEN | `0x401475bfed2b460c0d72a5ca7fe1125827472c080449184329417716b8ca91b8` |
| 7. Demo: **origin tx** — `updatePrice(1450e18)` | `0xb52343f511b0aea54e8d3447268957710d66947cce640280721d7e72349bceb4` |
| 7. Demo: **Lasna reactive tx** — `react()` → `GuardTriggered` + `CallbackRequest` | `0xec30518925864b5b1bd18458f3b1ecdaf146aba95ecaa6a9e609623692d8f40f` |
| 7. Demo: **callback tx** — proxy → `StopLossVault.executeExit` | **PENDING** (see below) |

Step-5 sanity checks all passed: `recipient()` == vault,
guard balance 5 lREACT, vault balance 0.05 ETH.

## Verification (Step 6, Sourcify — all exact_match)

| Contract | Match |
|---|---|
| PriceFeed (84532) | exact_match (creation + runtime) |
| StopLossVault (84532) | exact_match (creation + runtime) |
| ReactiveGuard (5318007) | exact_match (runtime) |

## Demo loop (Step 7) — status

Confirmed on-chain:

1. ✅ Deposit of 50 TOKEN into the vault (19:19:48 UTC).
2. ✅ Origin event: `updatePrice(1450e18)` at 19:19:50 UTC (block 60970610)
   emitted `PriceUpdated(1450e18, 1795115990)` — below the 1,500 stop-loss.
3. ✅ Reactive execution on Lasna (block 8755870): `GuardTriggered(reason=1,
   price=1450e18, originTimestamp=1795115990)` and a correctly formed
   `CallbackRequest` from the system contract — destination chain 84532,
   destination = the vault, gas limit 1,000,000, payload
   `executeExit(…, 1, 1450e18, 1795115990)`.
4. ⏳ **Callback delivery on Base Sepolia: not observed.** As of the last
   check (19:38 UTC, ~19 minutes after the origin event) the callback proxy
   (`0x476F44b11F5C942c58f4c8E3d0300E5710743585`) had not delivered: the
   vault's only transactions remain its creation and the deposit,
   `totalQuoteOut()` = 0, `loopLatencySeconds()` = 0, and the vault still
   holds the 50 TOKEN. Notably, the proxy's most recent `deliverCallback`
   for *anyone* was at 18:53:33 UTC — before our request — which points to
   a Reactive testnet relayer stall, not a defect in these contracts: the
   request was emitted correctly and both sides are funded (guard
   4.979331 lREACT after paying for the reactive tx; vault 0.05 ETH,
   untouched because billing happens at delivery).
5. ⏳ `withdrawQuote()` not called — there are no proceeds to withdraw yet.

**To finish the loop once the relayer delivers:** read
`loopLatencySeconds()` and `totalQuoteOut()` from the vault, record the
callback tx hash (the proxy → vault `executeExit` transaction), then call
`withdrawQuote()`. If the callback never lands, re-arm the guard
(`rearm(1500e18, 3000e18)` on Lasna, see DEPLOY.md) and repeat the demo —
note the vault position from this run is still in place.

## Final balances (as of 19:38 UTC, 2026-11-19)

| Account | Balance |
|---|---|
| Deployer, Base Sepolia | 0.035170895322867449 ETH |
| Deployer, Lasna | 0.330340899998303409 lREACT |
| ReactiveGuard, Lasna | 4.979331 lREACT |
| StopLossVault, Base Sepolia | 0.05 ETH + 50 TOKEN (position open) |
