# IGGY v3 — Quantitative AI Trading + Screen Learning

## What's new in v3

| Feature | Before | v3 |
|---|---|---|
| API keys | 2+ | **1 (OpenRouter only)** |
| Talking | Gibberish character RNN | Real LLM via OpenRouter |
| Trade analysis | Win/loss count only | **WHY it won/why it lost** |
| Learning | Manual data feeding | **Learns from screen automatically** |
| Indicators | MACD + ATR only | **RSI + BB + EMA cross + MACD + Volume + ATR** |
| Position sizing | Fixed | **Kelly Criterion (adapts to win rate)** |
| Stop loss | Fixed | **Trailing stop (activates at 1.2×ATR profit)** |
| Risk | None | **Daily -3% circuit breaker** |
| Regime | None | **TREND / RANGE / VOLATILE detection** |

---

## Setup (5 minutes)

### 1. Get your OpenRouter key
Go to https://openrouter.ai/keys → Create key → Copy it

### 2. Set environment variable
```bash
# Linux / Mac
export OPENROUTER_API_KEY=sk-or-...

# Windows
set OPENROUTER_API_KEY=sk-or-...

# Or create a .env file in your project folder:
echo "OPENROUTER_API_KEY=sk-or-..." > .env
```

### 3. Install Julia dependencies
```bash
julia -e 'import Pkg; Pkg.add(["HTTP", "JSON", "Dates", "Statistics", "SHA", "Base64", "Printf"])'
```

### 4. Install screenshot tool (Linux only)
```bash
sudo apt install scrot          # Ubuntu/Debian
# Mac: no install needed (uses built-in screencapture)
# Windows: no install needed (uses PowerShell)
```

### 5. Run IGGY
```bash
julia --threads 6 iggy_executive_v3.jl
```

---

## How the screen learning works

IGGY takes a screenshot every 30 seconds and sends it to **Gemini Flash** (a free vision model on OpenRouter). The model reads whatever is on screen — charts, text, code, browser tabs, apps — and extracts key insights. These are fed into IGGY's knowledge base and automatically used in all future conversations and trade decisions.

**What IGGY learns from your screen:**
- Trading charts → price levels, patterns, indicators
- Browser tabs → articles, news, market data
- Code editors → your codebase context
- Spreadsheets → financial data, strategies
- Terminal output → logs, trade results
- Any text document → strategies, notes, research

**IGGY also watches your project folder** for new or changed files (.csv, .log, .jl, .py, .json, .txt) and reads them automatically.

---

## How the quant learning works

After **every trade closes**, IGGY sends the full indicator state to the LLM and asks:
1. What was the PRIMARY cause of this win/loss?
2. Was the regime appropriate for the strategy?
3. What indicator combination to watch for next time?
4. One rule to add to the playbook.

These rules are saved to `iggy_brain_insights.json` and injected into every future trade decision and conversation.

---

## Chat commands

| Command | What it does |
|---|---|
| `status` | Show portfolio + brain summary |
| `vision` | Show vision system status |
| `read <path>` | Manually ingest a file |
| `url <url>` | Fetch + learn from a webpage |
| `insights` | Show last 10 learned trading rules |
| `screenshot` | Take + analyze a screenshot now |
| `exit` | Save and quit |
| Anything else | Chat with IGGY (trading-aware) |

---

## File structure

```
iggy_brain.jl           ← LLM brain, quant analyzer, screen knowledge store
iggy_trade_v3.jl        ← Trading engine (6 indicators, Kelly, trailing stop)
iggy_vision.jl          ← Screen capture + file watcher + knowledge extraction
iggy_executive_v3.jl    ← Unified launcher (run this)
iggy_cns_core.jl        ← Original core (still used for WebSocket + Binance REST)

iggy_brain_insights.json  ← Learned trading rules (auto-generated)
iggy_brain_memory.json    ← Screen knowledge store (auto-generated)
iggy_trade_v3_log.csv     ← Full trade log with indicators (auto-generated)
iggy_vision_log.json      ← Vision analysis log (auto-generated)
iggy_chat_log.json        ← Full conversation history (auto-generated)
```

---

## Trading engine details

### 6 Indicators (scored 0-6)
1. **EMA Cross** (9 vs 21) — trend direction
2. **RSI** (14) — overbought/oversold
3. **MACD histogram** — momentum
4. **Bollinger Bands** (20, 2σ) — range position or breakout
5. **Volume spike** (1.5× avg) — conviction
6. **Price vs 20-bar high-low midpoint** — momentum confirmation

### Regime detection
- **TREND**: EMA spread > 0.3% → Bollinger breakout continuation
- **RANGE**: default → Bollinger mean reversion
- **VOLATILE**: ATR/price > 0.8% → requires 4/6 score (stricter)

### Kelly Criterion sizing
- After 10+ trades: uses actual win rate and avg win/loss to size positions
- Capped at half-Kelly (safer), max 4% of balance per trade
- Falls back to 1.5% fixed risk before enough data

### Risk management
- **Trailing stop**: activates when floating profit ≥ 1.2×ATR, follows at 0.7×ATR
- **Daily circuit breaker**: halts all trading if daily PnL < -3%
- **Cooldown**: 3 bars between trades per symbol

---

## Models used (all via single OpenRouter key)

| Purpose | Model | Cost |
|---|---|---|
| Chat | claude-3-haiku | Very cheap |
| Trade analysis | claude-3-haiku | Very cheap |
| Screen vision | google/gemini-flash-1.5 | Free tier available |

Change models in `iggy_brain.jl` constants if you want different ones.
