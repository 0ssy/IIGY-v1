#
# NOTE
# ----
# This file is `include()`-d by `iggy_bridge.jl` and `iggy_executive.jl`.
# It must behave like a library — define types/constants/functions without
# auto-starting infinite loops on include.
#
# The trading runner is exposed via `run_cns_merged()` and only auto-runs when
# this file is the direct entrypoint (PROGRAM_FILE == @__FILE__).
#
# ─────────────────────────────────────────
# IGGY CNS v5.5 (MERGED) — ADAPTIVE TRADING EDITION
# Combines v5.2 advanced trading logic with v4.0 adaptive framework
# ─────────────────────────────────────────

function ensure(pkg)
    try
        eval(Meta.parse("using $pkg"))
    catch
        println("📦 Installing missing package: $pkg")
        @eval import Pkg
        Pkg.add(String(pkg))
        eval(Meta.parse("using $pkg"))
    end
end

ensure(:JSON)
ensure(:Dates)
ensure(:Statistics)
ensure(:HTTP)
ensure(:SHA)
ensure(:Printf)

using JSON, Dates, Statistics, Printf
using HTTP
using SHA

# ─────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────

const SYMBOLS         = ["BTCUSDT", "ETHUSDT", "SOLUSDT"]
const WS_BASE         = "wss://stream.testnet.binance.vision/ws"
const WS_BASE_URL     = "wss://stream.testnet.binance.vision/stream"
const KLINE_INTERVAL  = "1m"
const KLINE_LIMIT     = 200
const MAX_DD          = 0.50
const LOG_FILE        = "iggy_cns_log.txt"
const DOTENV_FILE     = ".env"
const STATE_FILE      = "iggy_cns_state.json"
const RISK_PER_TRADE  = 0.01   # 1% of notional balance per trade
const TP_MULT         = 2.0    # TP = entry ± 2×ATR
const SL_MULT         = 1.0    # SL = entry ± 1×ATR
const SIGNAL_THRESH   = 0.6    # MACD+bias must exceed this to enter
const MIN_ATR_RATIO   = 0.0002 # minimum ATR/price — skip if market is dead flat
const WARMUP_BARS     = 30     # bars needed before any signal fires
const COOLDOWN_BARS   = 3      # bars to wait after a trade before re-entering

# Execution is OFF by default (simulation mode).
const EXECUTE_ENV_FLAG      = "IGGY_EXECUTE_TESTNET"
const BINANCE_KEY_ENV       = "BINANCE_API_KEY"
const BINANCE_SECRET_ENV    = "BINANCE_API_SECRET"
const BINANCE_TESTNET_REST  = "https://testnet.binance.vision"

const READY_SUCCESS_THRESHOLD = 50
const READY_MIN_WINRATE       = 0.60
const READY_MAX_WINRATE       = 0.65

const DEFAULT_QTY = Dict(
    "BTCUSDT" => 0.001,
    "ETHUSDT" => 0.01,
    "SOLUSDT" => 0.1,
)

# Adaptive trading parameters (v4 enhancements)
const EXCHANGE_API_BASE = "https://api.binance.com"
const TESTNET_API_BASE = "https://testnet.binance.vision"

# ─────────────────────────────────────────
# STATE STRUCTURES
# ─────────────────────────────────────────

mutable struct OpenPosition
    symbol   :: String
    side     :: String   # "LONG" or "SHORT"
    entry    :: Float64
    size     :: Float64
    tp       :: Float64
    sl       :: Float64
    bar_open :: Int
end

mutable struct AdaptiveMemory
    outcomes    :: Vector{Float64}
    pnl_history :: Vector{Float64}
    cooldown    :: Int
end

AdaptiveMemory() = AdaptiveMemory(Float64[], Float64[], 0)

# ── V4-style structures for compatibility ──

mutable struct Capital
    total_usdt::Float64
    allocated::Float64
    available::Float64
    daily_pnl::Float64
    peak_balance::Float64
    # Legacy compatibility fields
    balance :: Float64
    peak    :: Float64
    dd      :: Float64
    
    function Capital(total::Float64, alloc::Float64=0.0, avail::Float64=0.0, pnl::Float64=0.0, peak::Float64=0.0)
        c = new()
        c.total_usdt = total
        c.allocated = alloc
        c.available = avail
        c.daily_pnl = pnl
        c.peak_balance = peak
        # Legacy
        c.balance = total
        c.peak = peak
        c.dd = 0.0
        return c
    end
end

mutable struct Strategy
    name::String
    risk_per_trade::Float64
    max_drawdown::Float64
    take_profit_mult::Float64
    stop_loss_mult::Float64
    regime::Symbol # :bull, :bear, :sideways
    # Legacy compatibility
    risk      :: Float64
    weights   :: Vector{Float64}
    threshold :: Float64
    
    function Strategy(name="Adaptive-Merged", risk=0.02, dd=0.1, tp=2.0, sl=1.0, regime=:sideways)
        s = new()
        s.name = name
        s.risk_per_trade = risk
        s.max_drawdown = dd
        s.take_profit_mult = tp
        s.stop_loss_mult = sl
        s.regime = regime
        # Legacy
        s.risk = risk
        s.weights = [0.33, 0.33, 0.34]
        s.threshold = SIGNAL_THRESH
        return s
    end
end

mutable struct Asset
    symbol      :: String
    base_asset  :: String
    quote_asset :: String
    precision   :: Int
    min_notional:: Float64
    # Extended fields for full trading state
    price       :: Float64
    prev        :: Float64
    high        :: Float64
    low         :: Float64
    open        :: Float64
    volume      :: Float64
    closes      :: Vector{Float64}
    highs       :: Vector{Float64}
    lows        :: Vector{Float64}
    pressure    :: Float64
    trend       :: Float64
    atr_val     :: Float64
    macd_val    :: Float64
    regime      :: Int
    conf        :: Float64
    ema_fast    :: Float64
    ema_slow    :: Float64
    macd_fast   :: Float64
    macd_slow   :: Float64
    signal_line :: Float64
    macd_line   :: Float64
end

mutable struct Position
    symbol :: String
    side   :: Symbol # :long, :short, :none
    entry_price :: Float64
    quantity :: Float64
    unrealized_pnl :: Float64
    entry_time :: DateTime
    # Legacy compatibility
    side_int :: Int
    size :: Float64
end

mutable struct Brain
    confidence :: Float64
    mode       :: Symbol
    cooldown   :: Int
end

# ─────────────────────────────────────────
# GLOBAL STATE
# ─────────────────────────────────────────

price_cache = Dict{String, Vector{Float64}}()
open_pos    = Dict{String, OpenPosition}()
adapt_mem   = Dict{String, AdaptiveMemory}()
total_pnl   = Dict{String, Float64}()
bar_count   = Dict{String, Int}()

successful_trades  = Ref(0)
failed_trades      = Ref(0)
ready_notice_sent  = Ref(false)

for s in SYMBOLS
    price_cache[s] = Float64[]
    adapt_mem[s]   = AdaptiveMemory()
    total_pnl[s]   = 0.0
    bar_count[s]   = 0
end

# ─────────────────────────────────────────
# INITIALIZATION
# ─────────────────────────────────────────

"""
    initialize_iggy_state(; symbols, balance) -> (Capital, Strategy, Dict, Dict, Dict, Channel)

Creates and returns the full state tuple needed by trading loop and iggy_bridge.jl.
"""
function initialize_iggy_state(;
        symbols  :: Vector{String} = SYMBOLS,
        balance  :: Float64        = 1000.0)

    capital  = Capital(balance, 0.0, balance, 0.0, balance)
    strategy = Strategy("Adaptive-Merged", RISK_PER_TRADE, MAX_DD, TP_MULT, SL_MULT)
    kline_ch = Channel{Dict}(256)

    assets    = Dict{String, Asset}()
    brains    = Dict{String, Brain}()
    positions = Dict{String, Position}()

    for s in symbols
        assets[s] = Asset(s, "", "", 8, 10.0,
                          0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                          Float64[], Float64[], Float64[],
                          0.0, 0.0, 0.0, 0.0, 0, 0.0,
                          0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        brains[s]    = Brain(0.5, :IDLE, 0)
        positions[s] = Position(s, :none, 0.0, 0.0, 0.0, now(), 0, 0.0)
    end

    return capital, strategy, assets, brains, positions, kline_ch
end

# ─────────────────────────────────────────
# .env loader
# ─────────────────────────────────────────

function load_dotenv!(path::String = DOTENV_FILE)
    isfile(path) || return false
    for raw in eachline(path)
        line = strip(raw)
        isempty(line) && continue
        startswith(line, "#") && continue
        occursin("=", line) || continue
        k, v = split(line, "=", limit=2)
        key = strip(k); val = strip(v)
        if (startswith(val, "\"") && endswith(val, "\"")) ||
           (startswith(val, "'")  && endswith(val, "'"))
            val = val[2:end-1]
        end
        if !isempty(key) && !haskey(ENV, key)
            ENV[key] = val
        end
    end
    return true
end

load_dotenv!()

# ─────────────────────────────────────────
# Persistent state
# ─────────────────────────────────────────

function save_runtime_state!()
    state = Dict(
        "successful_trades" => successful_trades[],
        "failed_trades"     => failed_trades[],
        "ready_notice_sent" => ready_notice_sent[],
        "saved_at"          => string(now()),
    )
    open(STATE_FILE, "w") do f; JSON.print(f, state) end
end

function load_runtime_state!()
    isfile(STATE_FILE) || return false
    try
        st = JSON.parsefile(STATE_FILE)
        successful_trades[] = Int(get(st, "successful_trades", 0))
        failed_trades[]     = Int(get(st, "failed_trades", 0))
        ready_notice_sent[] = Bool(get(st, "ready_notice_sent", false))
        return true
    catch
        return false
    end
end

if load_runtime_state!()
    println("📂 Loaded runtime state | wins=$(successful_trades[]) " *
            "losses=$(failed_trades[]) ready_sent=$(ready_notice_sent[])")
end

# ─────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────

function log_trade(msg::String)
    ts   = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
    line = "[$ts][TRADE] $msg"
    println(line)
    open(LOG_FILE, "a") do f; println(f, line) end
end

function log_info(msg::String)
    ts   = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
    line = "[$ts][INFO] $msg"
    println(line)
    open(LOG_FILE, "a") do f; println(f, line) end
end

function maybe_notify_ready_for_real_account()
    total_closed = successful_trades[] + failed_trades[]
    total_closed == 0 && return
    winrate          = successful_trades[] / total_closed
    enough_successes = successful_trades[] >= READY_SUCCESS_THRESHOLD
    in_target_band   = READY_MIN_WINRATE <= winrate <= READY_MAX_WINRATE

    if !ready_notice_sent[] && enough_successes && in_target_band
        ready_notice_sent[] = true
        msg = @sprintf(
            "READY CHECK: %d wins, %d losses, winrate %.2f%% (target %.0f-%.0f%%).",
            successful_trades[], failed_trades[], 100*winrate,
            100*READY_MIN_WINRATE, 100*READY_MAX_WINRATE)
        log_info(msg)
        println("🔔🔔🔔 $msg")
    elseif enough_successes && !in_target_band
        msg = @sprintf(
            "READINESS HOLD: wins=%d losses=%d winrate=%.2f%% (target %.0f-%.0f%%).",
            successful_trades[], failed_trades[], 100*winrate,
            100*READY_MIN_WINRATE, 100*READY_MAX_WINRATE)
        log_info(msg)
    end
end

# ─────────────────────────────────────────
# TECHNICAL INDICATORS (V4 merged style)
# ─────────────────────────────────────────

function calculate_indicators(prices::Vector{Float64})
    if length(prices) < 20
        return Dict(:sma20 => 0.0, :rsi => 50.0, :volatility => 0.0, :atr => 0.0)
    end
    
    sma20 = mean(prices[end-19:end])
    
    # RSI calculation
    deltas = diff(prices)
    gains = [d > 0 ? d : 0.0 for d in deltas]
    losses = [d < 0 ? abs(d) : 0.0 for d in deltas]
    avg_gain = mean(gains[end-13:end])
    avg_loss = mean(losses[end-13:end])
    rs = avg_loss == 0 ? 100.0 : avg_gain / avg_loss
    rsi = 100.0 - (100.0 / (1.0 + rs))
    
    volatility = std(prices[end-19:end]) / mean(prices[end-19:end])
    
    # ATR (simplified)
    atr = mean(abs.(diff(prices[max(1,end-13):end])))
    
    return Dict(:sma20 => sma20, :rsi => rsi, :volatility => volatility, :atr => atr)
end

function detect_regime(prices::Vector{Float64}, indicators::Dict)
    if length(prices) < 50
        return :sideways
    end
    
    sma50 = mean(prices[end-49:end])
    current_price = prices[end]
    
    if current_price > sma50 && indicators[:rsi] > 55
        return :bull
    elseif current_price < sma50 && indicators[:rsi] < 45
        return :bear
    else
        return :sideways
    end
end

function generate_signal(regime::Symbol, indicators::Dict, current_price::Float64)
    if regime == :bull && indicators[:rsi] < 40
        return :buy
    elseif regime == :bear && indicators[:rsi] > 60
        return :sell
    elseif indicators[:rsi] > 75
        return :sell # Overbought
    elseif indicators[:rsi] < 25
        return :buy # Oversold
    else
        return :hold
    end
end

# ─────────────────────────────────────────
# EXECUTION LOGIC
# ─────────────────────────────────────────

function execute_trade(symbol::String, side::Symbol, quantity::Float64, price::Float64)
    println("🚀 EXECUTION: $side $quantity of $symbol at $price")
    # Real API call logic would go here
    return true
end

function execute_trade_binance(;
        symbol :: String,
        side   :: String,  # "BUY" or "SELL"
        qty    :: Float64)
    
    log_trade("$side $qty $symbol")
    # Real Binance API integration would go here
    return true
end

# ─────────────────────────────────────────
# MAIN TRADING LOOPS
# ─────────────────────────────────────────

"""
    run_cns_merged(symbol::String, capital::Capital, strategy::Strategy)

Main CNS trading loop combining v4 and v5.2 features.
Runs indefinitely, managing positions and executing trades.
"""
function run_cns_merged(symbol::String, capital::Capital, strategy::Strategy)
    println("🧠 IGGY CNS v5.5 (MERGED) starting for $symbol...")
    
    prices = Float64[]
    
    while true
        try
            # 1. Fetch latest price (Simulated)
            current_price = 50000.0 + randn() * 100.0 
            push!(prices, current_price)
            if length(prices) > 100; popfirst!(prices); end
            
            # 2. Calculate indicators and regime
            indicators = calculate_indicators(prices)
            regime = detect_regime(prices, indicators)
            
            # 3. Generate signal
            signal = generate_signal(regime, indicators, current_price)
            
            # 4. Logic for entering/exiting positions based on signal and capital
            if signal == :buy && capital.available > 0
                qty = (capital.available * strategy.risk_per_trade) / current_price
                execute_trade(symbol, :buy, qty, current_price)
                capital.available -= qty * current_price
                capital.allocated += qty * current_price
            elseif signal == :sell && capital.allocated > 0
                execute_trade(symbol, :sell, capital.allocated / current_price, current_price)
                capital.available += capital.allocated
                capital.allocated = 0.0
            end
            
            # 5. Status update
            sleep(5)
            
        catch e
            println("❌ Error in CNS loop: $e")
            sleep(10)
        end
    end
end

# ─────────────────────────────────────────
# HELPER FUNCTIONS
# ─────────────────────────────────────────

function get_iggy_stats(iggy::NamedTuple)
    return Dict(
        "balance" => iggy.capital.balance,
        "wins" => successful_trades[],
        "losses" => failed_trades[],
        "timestamp" => string(now())
    )
end

function build_trade_context_string(iggy::NamedTuple) :: String
    lines = String[]
    push!(lines, @sprintf("Balance: %.2f | DD: %.2f%%",
        iggy.capital.balance, iggy.capital.dd * 100))
    
    wins  = successful_trades[]
    total = wins + failed_trades[]
    wr    = total == 0 ? 0.0 : wins / total
    
    push!(lines, @sprintf("Trades: %d (%.1f%% win)", total, 100*wr))
    return join(lines, "\n")
end

# ─────────────────────────────────────────
# Entrypoint for Testing
# ─────────────────────────────────────────

if PROGRAM_FILE == @__FILE__
    cap = Capital(1000.0, 0.0, 1000.0, 0.0, 1000.0)
    strat = Strategy("Adaptive-Merged", 0.02, 0.1, 2.0, 1.0, :sideways)
    run_cns_merged("BTCUSDT", cap, strat)
end