# GridBot — Frequently Asked Questions (FAQ)

---

## Table of Contents

1. [Deployment & Setup](#1-deployment--setup)
2. [Planner Dashboard](#2-planner-dashboard)
3. [Guardian Hedging](#3-guardian-hedging)
4. [Dredging & Cannibalism](#4-dredging--cannibalism)
5. [Risk & Hard Stop](#5-risk--hard-stop)
6. [Time Zones](#6-time-zones)
7. [Communication & GlobalVariables](#7-communication--globalvariables)
8. [Grid Philosophy — The Ideal Grid That Never Stops](#8-grid-philosophy--the-ideal-grid-that-never-stops)
9. [Hedge Cost & Swap-Free Considerations](#9-hedge-cost--swap-free-considerations)

---

## 1. Deployment & Setup

### Q: What is the correct startup sequence for the 3 bots?

**Planner → Executor → Guardian**

1. **Planner first** — configure grid parameters, run simulation, click PUSH TO LIVE (writes 9 GlobalVariables)
2. **Executor second** — polls for Planner GVs every 10s, reads parameters, builds the grid
3. **Guardian last** — monitors the Executor's positions, only acts if DD triggers are hit

The Executor needs Planner's GVs to exist before it can build the grid. The Guardian needs the Executor running so it has positions to monitor.

### Q: How do I deploy on a new symbol (e.g., BTCUSDm)?

1. Pick a **unique magic number** for the new instance (e.g., 205003)
2. Open 3 charts of the new symbol (e.g., BTCUSDm)
3. Attach **Planner** — set `InpExecutorMagic` to your magic, configure grid range, run simulation, PUSH TO LIVE
4. Attach **Executor** — set `InpMagicNumber` to the same magic
5. Attach **Guardian** — set `InpMonitorMagic` to the same magic, set `InpHedgeMagic` to a unique hedge ID
6. Verify GVs in Tools → Global Variables (look for `{magic}_SG_*` entries)

### Q: Can I run multiple instances (e.g., Gold + BTC)?

Yes. Each instance needs:
- Its own set of 3 charts (Planner + Executor + Guardian)
- A unique magic number (e.g., 205001 for Gold, 205003 for BTC)
- A unique Guardian hedge magic (e.g., 999999 for Gold, 999998 for BTC)

---

## 2. Planner Dashboard

### Q: What does "Spread: 1800 pts" mean on the dashboard?

Spread is the difference between Bid and Ask price, measured in MT5 points (smallest price increment). For BTCUSDm where 1 point = $0.01:

- 1800 points = **$18.00 spread**

This is the cost you pay on every trade entry. The dashboard now shows both: `Spread: 1800 pts ($18.00)`.

### Q: What happens when the grid gap is less than the spread?

This is a critical problem:

- **Instant loss on every fill** — the TP target (roughly 1 gap) is already behind the Bid at entry. The trade is born underwater.
- **Churn with no recovery** — price bouncing between tight levels triggers entries, but none can reach TP.
- **Negative expectancy** — every grid trade costs more in spread than it earns.

**Prevention:**
- Widen the grid range or reduce levels to increase gap size
- Set `InpMaxSpreadPoints` on the Executor to reject trades when spread is too wide
- Monitor the Planner's First Gap vs spread ratio (First Gap should be at least 3x the spread)

### Q: What do First Gap and Last Gap mean?

- **First Gap** — spacing between the top grid levels (smallest gap, most vulnerable to spread)
- **Last Gap** — spacing between the bottom grid levels (widened by the condensing coefficient)

With a condensing coefficient > 1.0, gaps progressively widen from top to bottom. The First Gap is always the tightest and most at risk of being smaller than the spread.

---

## 3. Guardian Hedging

### Q: What are the hedge stages and when do they trigger?

The Guardian uses staggered hedging — gradually increasing SELL hedge volume as DD worsens:

| Stage | Default Trigger | Hedge Volume |
|---|---|---|
| Standby | DD < T1 | No hedge (monitoring only) |
| Stage 1 | DD >= T1 (30%) | SELL at 30% of grid volume |
| Stage 2 | DD >= T2 (35%) | SELL at ~60% of grid volume |
| Stage 3 | DD >= T3 (40%) | SELL at ~95% of grid volume |
| Hard Stop | DD >= 45% | Close ALL positions (grid + hedge) |
| Safe Unwind | DD < 20% + price in range | Close hedge, resume grid |

**Important:** If Risk Auto-Scaling is enabled (`InpAutoScaleToRisk = true`), these percentages are scaled down based on the grid's published `MAX_RISK_PCT`. See the Risk Auto-Scaling FAQ below.

### Q: What is Risk Auto-Scaling and how does it change the triggers?

When enabled, the Guardian reads the grid's `MAX_RISK_PCT` GlobalVariable and compresses all triggers proportionally:

```
scale = MAX_RISK_PCT / InpHardStopDD
```

**Example:** If `MAX_RISK_PCT = 25%` and `InpHardStopDD = 45%`:
```
scale = 25 / 45 = 0.5556

Effective T1:       30% × 0.5556 = 16.7%
Effective T2:       35% × 0.5556 = 19.4%
Effective T3:       40% × 0.5556 = 22.2%
Effective Hard Stop: = 25.0% (equals MAX_RISK_PCT)
Effective Unwind:   20% × 0.5556 = 11.1%
```

The entire progression from Standby → Hard Stop happens within a tighter band, making the Guardian more responsive.

### Q: Why does the system hedge at 95% and not 100%?

A 100% hedge creates a **permanently locked loss** with no way out:

| Hedge % | Behavior |
|---|---|
| **95%** | Near-total protection, but 5% gap allows recovery + cannibalism to work |
| **100%** | Completely frozen — loss locked, double swap drain, no recovery possible |

The 5% gap (unhedged exposure) is intentional because:
1. **Cannibalism works** — hedge profits slightly exceed grid losses, generating surplus to close bad positions
2. **Recovery is possible** — if price bounces, the grid recovers faster than the hedge loses
3. **Self-healing** — cannibalism gradually reduces grid size, making future unwinds cleaner

A 100% hedge is like a financial coma — alive but not living, while swap costs keep bleeding the account.

---

## 4. Dredging & Cannibalism

### Q: What is dredging?

Dredging is the Executor's self-cleaning mechanism during **normal trading**:

- Zone 2 and Zone 3 take-profit wins accumulate in a "bucket"
- When the bucket balance is enough to cover the worst-loss position, the Executor closes that position
- The grid gets progressively cleaner over time

### Q: What is cannibalism?

Cannibalism is the Guardian's grid-cleaning mechanism during an **active hedge**:

- The hedge SELL position generates profit as price drops
- When hedge profit exceeds the minimum threshold ($100 + $20 buffer in your settings), the Guardian closes the worst-loss grid position using that profit
- The grid shrinks, reducing total exposure

### Q: Are dredging and cannibalism the same thing?

No. Same goal (close worst-loss positions), but different mechanisms:

| | Dredging | Cannibalism |
|---|---|---|
| **Who** | Executor | Guardian |
| **When** | Normal trading (no hedge active) | During active hedge only |
| **Funded by** | Zone 2/3 TP profits (bucket) | Hedge SELL profit |
| **Runs simultaneously?** | No — Executor is FROZEN during hedging |

They work in **relay**: dredging during normal operation → cannibalism during crisis → dredging resumes after hedge unwinds.

---

## 5. Risk & Hard Stop

### Q: How much does BTC price need to drop for the hard stop?

For a grid with Upper=$69,899, Lower=$67,157, 25 levels (lots: 0.53/1.32/3.18):

**Without hedging (Guardian disabled):**
- Total grid loss at grid bottom ($67,157): ~$36,241
- Hard stop ($46,824) requires ~$305 more below grid
- **Hard stop price: ~$66,852** (drop of ~$3,047 / 4.4% from grid top)

**With hedging (all 3 stages active):**
- Stage 3 hedge covers 95% of volume, leaving only ~1.78 lots unhedged
- Price must drop significantly further — estimated **$64,000–$65,000 range**
- Exact price depends on hedge entry prices and slippage

### Q: What are the two hard stop mechanisms?

| | Executor Hard Stop | Guardian Hard Stop |
|---|---|---|
| **Set by** | `InpHardStopDDPct` (% from peak balance) | Guardian `InpHardStopDD` (% DD) |
| **Triggers at** | Equity drops below `peakBalance × (1 - pct%)` | Total drawdown exceeds hard stop % |
| **Action** | Executor closes all grid positions and halts | Guardian closes ALL positions across all magic numbers |
| **Reversible?** | No — Executor stops trading | No — everything is liquidated |

The Executor hard stop tracks **peak realized balance** so the floor rises as the account grows and never drifts dangerously close to current equity. Both are kill switches, not pauses — the grid's recovery mechanism (averaging down) runs freely until these limits are hit.

---

## 6. Time Zones

### Q: What are the three time zones shown on the Executor dashboard?

| Clock | Source | What It Shows |
|---|---|---|
| **Broker** | `TimeCurrent()` | MT5 server time (varies by broker, often UTC+0 or UTC+2/+3) |
| **VPS** | `TimeLocal()` | Your VPS machine's OS clock (depends on VPS region) |
| **PKT** | `TimeGMT() + 5h` | Pakistan Standard Time (UTC+5, no daylight saving) |

All three show **different times** from different time zones. Example at 7:00 PM Pakistan time:
```
Broker: 14:00  |  VPS: 09:00  |  PKT: 19:00
```

---

## 7. Communication & GlobalVariables

### Q: How do the 3 bots communicate?

Exclusively through MT5 **GlobalVariables** (GVs). No files, no network, no shared memory.

- Planner writes `{magic}_SG_OPT_*` GVs via PUSH TO LIVE
- Executor reads those GVs every 10s and writes `{magic}_SG_*` state GVs
- Guardian reads Executor's GVs and writes `{hedgeMagic}_GH_*` GVs

### Q: What does the `{magic}_SG_HEDGE_ACTIVE` GV do?

When the Guardian opens a hedge, it sets `{magic}_SG_HEDGE_ACTIVE = 1`. The Executor reads this every tick and **freezes** — no new trades, no dredging, no grid shifts. When the Guardian unwinds the hedge, it resets to 0 and the Executor resumes.

---

## 8. Grid Philosophy — The Ideal Grid That Never Stops

### Q: Should I prioritize a wider range or rely on the hedging system?

**Wider range wins. Every time.**

The core philosophy of grid trading is **perpetual cash flow** — price oscillates, trades hit TP, profits accumulate forever. The grid should never need to be rescued. If the Guardian is activating regularly, the problem isn't the Guardian — it's the grid design.

### Why Hedging Is Admission of Failure

```
Wide enough range  →  Price stays inside  →  Dredging cleans up  →  Grid runs forever
                       No hedge needed. No freeze. No cannibalism.

Too narrow range   →  Price escapes  →  DD spikes  →  Guardian activates
                       Executor freezes  →  No more TP wins  →  No dredging
                       Now depending on hedge profit to survive.
                       The grid is no longer trading. It's in ICU.
```

The moment the Guardian activates, the grid has stopped being a grid. It's a locked position pair bleeding swap — the opposite of grid trading philosophy.

### The Trade-Off: Frequency vs Survivability

| Wider Range | Narrower Range |
|---|---|
| Larger gaps between levels | Tighter gaps, more frequent TPs |
| Fewer trades hit per day | More trades hit per day |
| Smaller lot sizes (same capital) | Larger lots possible |
| **Survives crashes** | **Dies in crashes** |
| Slow steady income | Fast income until it breaks |

### Priority Order for Grid Design

```
1. RANGE FIRST     — wide enough to survive the worst drop you can tolerate
2. DREDGING        — let the bucket system clean up naturally over weeks/months
3. LOT SIZING      — smaller lots = wider range = longer survival
4. HEDGING LAST    — safety net only, should almost never activate
```

### The Fire Extinguisher Analogy

Think of the Guardian as a **fire extinguisher**, not a cooking tool:

- You **design the kitchen** (grid range) so fires almost never happen
- You **keep the extinguisher** (Guardian) mounted on the wall just in case
- If you're **using the extinguisher every week**, the problem isn't the extinguisher — it's the kitchen design

### Practical Example: BTC

| Approach | Range | Survives |
|---|---|---|
| Narrow (4%) | $67,157–$69,899 | ~$3,000 drop before hard stop |
| Wide (22%) | $60,000–$75,000 | ~$15,000+ drop |
| Very wide (37%) | $55,000–$80,000 | ~$25,000+ drop |

A 4% range on BTC is dangerously narrow — BTC regularly moves 5–10% in a single day. The entire grid can be blown through in hours.

### Bottom Line

> **A grid that needs hedging is a grid that was designed too tight.**
> Widen the range, reduce the lots, let dredging do its job.
> The Guardian should be insurance you hope to never use — not a crutch you lean on daily.

---

## 9. Hedge Cost & Swap-Free Considerations

### Q: Hedging feels like a costly insurance policy — where does the cost come from?

When the Guardian unwinds a hedge, the SELL positions are closed at a loss (price recovered upward). The total cost comes from:

| Cost Component | Normal Account | Swap-Free Account |
|---|---|---|
| **Spread on hedge OPEN** | Yes — BTC spread × hedge lots | Same |
| **Spread on hedge CLOSE** | Yes — paid again on unwind | Same |
| **Swap drain (nightly)** | Yes — biggest ongoing cost, can be $50-200+/night on BTC | **$0** |
| **Hedge closing loss** | Yes — the bulk of the cost | Same |
| **Cannibalism realized losses** | Yes — each eaten grid position locks in a loss | Same |

On a **normal account**, swap is the silent killer — it bleeds equity every night the hedge is open. On a **swap-free account**, the cost is purely spread + the hedge's closing loss.

### Q: How do I reduce hedging costs?

**Option 1 — Avoid the hedge entirely (best):**
Wider range = hedge never triggers = cost is $0.

**Option 2 — Tune Guardian settings:**

| Setting | Effect on Cost |
|---|---|
| Lower hedge ratios (95% → 70%) | ~25% less spread cost + smaller closing loss |
| Lower `InpSafeUnwindDD` (20% → 15%) | Hedge closes sooner = less time exposed |
| Lower `InpMinHedgeProfit` ($100 → $50) | Cannibalism fires more often = grid shrinks faster during hedge |
| Lower `InpForceCloseHours` (72 → 48) | Caps maximum duration (mainly benefits swap accounts) |

### Q: Does swap-free change the hedging strategy?

Yes, significantly. Swap-free removes the time penalty entirely:

| Factor | Swap Account | Swap-Free Account |
|---|---|---|
| **Holding cost per day** | $50-200+ (swap drain) | **$0** |
| **Time pressure to unwind** | High — every hour costs money | **None** — hedge can wait patiently |
| **Force-close timer importance** | Critical — cap the bleed | Less important — no ongoing bleed |
| **Hedge ratios** | Lower = cheaper (less swap) | Current 30/60/95% is more acceptable |
| **Cannibalism urgency** | High — race against swap clock | Still beneficial but no time pressure |

**On swap-free, hedging is much cheaper insurance.** The Guardian can hold the hedge patiently, let cannibalism do its work, and wait for a clean recovery without the swap clock ticking.

### Q: Is the hedge cost worth it?

Ask: **What was the grid's unrealized loss when the hedge activated?**

- If the grid was down $30,000+ and the hedge prevented it from becoming $50,000+ → paying $5,000 saved $20,000. That's 25 cents per dollar protected. **Good insurance.**
- If the grid only dipped briefly and would have recovered on its own → the $5,000 was wasted. **Bad timing.**

The hedge doesn't know the future. It activates based on DD thresholds. Sometimes it saves you, sometimes it costs you unnecessarily — just like real insurance.

> **On swap-free accounts, the break-even point is much more favorable.** Without swap drain, even a hedge that was "unnecessary" only costs spread + closing loss — not spread + closing loss + days of swap fees.

---

*Last updated: 2026-02-24*
