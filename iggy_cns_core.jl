#
# NOTE
# ----
# This file is `include()`-d by `iggy_bridge.jl` and `iggy_executive.jl`.
# It must behave like a library — define types/constants/functions without
# auto-starting infinite loops on include.
#
# The trading runner is exposed via `run_cns_v5()` and only auto-runs when
# this file is the direct entrypoint (PROGRAM_FILE == @__FILE__).
#

# ─────────────────────────────────────────
# IGGY CNS v5.1 — ADAPTIVE TRADING EDITION
# TESTNET ONLY
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

using JSON, Dates, Statistics, Printf
using HTTP
using SHA

# ─────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────
const SYMBOLS        = ["BTCUSDT", "ETHUSDT", "SOLUSDT"]
const WS_BASE        = "wss://stream.testnet.binance.vision/ws"
const WS_BASE_URL    = "wss://stream.testnet.binance.vision/stream"
const KLINE_INTERVAL = "1m"
const KLINE_LIMIT    = 200
const MAX_DD         = 0.50
const LOG_FILE       = "iggy_cns_log.txt"
const DOTENV_FILE    = ".env"
const STATE_FILE     = "iggy_cns_state.json"

const RISK_PER_TRADE = 0.01   # 1% of notional balance per trade
const TP_MULT        = 2.0    # TP = entry ± 2×ATR
const SL_MULT        = 1.0    # SL = entry ± 1×ATR
const SIGNAL_THRESH  = 0.6    # MACD+bias must exceed this to enter
const MIN_ATR_RATIO  = 0.0002 # minimum ATR/price — skip if market is dead flat
const WARMUP_BARS    = 30     # bars needed before any signal fires
const COOLDOWN_BARS  = 3      # bars to wait after a trade before re-entering

# Execution is OFF by default (simulation mode).
# Set `IGGY_EXECUTE_TESTNET=1` to enable placing Binance TESTNET orders.
const EXECUTE_ENV_FLAG = "IGGY_EXECUTE_TESTNET"
const BINANCE_KEY_ENV = "BINANCE_API_KEY"
const BINANCE_SECRET_ENV = "BINANCE_API_SECRET"
const BINANCE_TESTNET_REST = "https://testnet.binance.vision"
const READY_SUCCESS_THRESHOLD = 50
const READY_MIN_WINRATE = 0.60
const READY_MAX_WINRATE = 0.65

# Default spot quantities (override per-symbol via env var: IGGY_QTY_BTCUSDT, etc.)
const DEFAULT_QTY = Dict(
    "BTCUSDT" => 0.001,
    "ETHUSDT" => 0.01,
    "SOLUSDT" => 0.1,
)

# ─────────────────────────────────────────
# STATE
# ─────────────────────────────────────────
mutable struct OpenPosition
    symbol   :: String
    side     :: String   # "LONG" or "SHORT"
    entry    :: Float64
    size     :: Float64
    tp       :: Float64
    sl       :: Float64
    bar_open :: Int      # price_cache length when opened
end

# Per-symbol adaptive memory: rolling window of recent PnL outcomes
mutable struct AdaptiveMemory
    outcomes    :: Vector{Float64}  # +1 profit, -1 loss, 0 scratch
    pnl_history :: Vector{Float64}  # actual pnl values
    cooldown    :: Int              # bars remaining before next entry
end

AdaptiveMemory() = AdaptiveMemory(Float64[], Float64[], 0)

price_cache  = Dict{String, Vector{Float64}}()
open_pos     = Dict{String, OpenPosition}()    # at most one position per symbol
adapt_mem    = Dict{String, AdaptiveMemory}()
total_pnl    = Dict{String, Float64}()
bar_count    = Dict{String, Int}()
successful_trades = Ref(0)
failed_trades = Ref(0)
ready_notice_sent = Ref(false)

for s in SYMBOLS
    price_cache[s] = Float64[]
    adapt_mem[s]   = AdaptiveMemory()
    total_pnl[s]   = 0.0
    bar_count[s]   = 0
end

# ─────────────────────────────────────────
# .env loader (optional)
# ─────────────────────────────────────────
function load_dotenv!(path::String = DOTENV_FILE)
    isfile(path) || return false
    for raw in eachline(path)
        line = strip(raw)
        isempty(line) && continue
        startswith(line, "#") && continue
        occursin("=", line) || continue
        k, v = split(line, "=", limit=2)
        key = strip(k)
        val = strip(v)
        # remove simple surrounding quotes
        if (startswith(val, "\"") && endswith(val, "\"")) || (startswith(val, "'") && endswith(val, "'"))
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
# Persistent state (wins/losses/readiness)
# ─────────────────────────────────────────
function save_runtime_state!()
    state = Dict(
        "successful_trades" => successful_trades[],
        "failed_trades" => failed_trades[],
        "ready_notice_sent" => ready_notice_sent[],
        "saved_at" => string(now()),
    )
    open(STATE_FILE, "w") do f
        JSON.print(f, state)
    end
end

function load_runtime_state!()
    isfile(STATE_FILE) || return false
    try
        st = JSON.parsefile(STATE_FILE)
        successful_trades[] = Int(get(st, "successful_trades", 0))
        failed_trades[] = Int(get(st, "failed_trades", 0))
        ready_notice_sent[] = Bool(get(st, "ready_notice_sent", false))
        return true
    catch
        return false
    end
end

if load_runtime_state!()
    println("📂 Loaded runtime state | wins=$(successful_trades[]) losses=$(failed_trades[]) ready_sent=$(ready_notice_sent[])")
end

# ─────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────
function log_trade(msg::String)
    ts  = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
    line = "[$ts][TRADE] $msg"
    println(line)
    open(LOG_FILE, "a") do f
        println(f, line)
    end
end

function log_info(msg::String)
    ts  = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
    line = "[$ts][INFO] $msg"
    println(line)
    open(LOG_FILE, "a") do f
        println(f, line)
    end
end

function maybe_notify_ready_for_real_account()
    total_closed = successful_trades[] + failed_trades[]
    if total_closed == 0
        return
    end

    winrate = successful_trades[] / total_closed
    enough_successes = successful_trades[] >= READY_SUCCESS_THRESHOLD
    in_target_band = READY_MIN_WINRATE <= winrate <= READY_MAX_WINRATE

    if !ready_notice_sent[] && enough_successes && in_target_band
        ready_notice_sent[] = true
        msg = @sprintf(
            "READY CHECK: %d wins, %d losses, winrate %.2f%% (target %.0f-%.0f%%). Candidate for real-account review.",
            successful_trades[], failed_trades[], 100*winrate, 100*READY_MIN_WINRATE, 100*READY_MAX_WINRATE
        )
        log_info(msg)
        println("🔔🔔🔔 $msg")
    elseif enough_successes && !in_target_band
        # Non-terminal progress signal: enough wins reached but quality band not met yet.
        msg = @sprintf(
            "READINESS HOLD: wins=%d losses=%d winrate=%.2f%% (target %.0f-%.0f%%).",
            successful_trades[], failed_trades[], 100*winrate, 100*READY_MIN_WINRATE, 100*READY_MAX_WINRATE
        )
        log_info(msg)
    end
end

# ─────────────────────────────────────────
# Binance TESTNET execution (optional)
# ─────────────────────────────────────────
is_execution_enabled() = get(ENV, EXECUTE_ENV_FLAG, "") in ("1", "true", "TRUE", "yes", "YES")

function hmac_sha256_hex(key::AbstractString, msg::AbstractString)
    return bytes2hex(hmac_sha256(Vector{UInt8}(key), Vector{UInt8}(msg)))
end

function place_testnet_order_test(symbol::String, side::String; quantity::Float64)
    # Uses Binance TESTNET: /api/v3/order/test (validates signature and parameters).
    api_key = get(ENV, BINANCE_KEY_ENV, "")
    api_secret = get(ENV, BINANCE_SECRET_ENV, "")
    if api_key == "" || api_secret == ""
        log_info("Execution disabled: missing $BINANCE_KEY_ENV / $BINANCE_SECRET_ENV (load via env vars or .env).")
        return false
    end

    endpoint = "/api/v3/order/test"
    timestamp = Int64(floor(datetime2unix(now(Dates.UTC)) * 1000))
    recv = 5000
    qs = "symbol=$(uppercase(symbol))&side=$side&type=MARKET&quantity=$quantity&timestamp=$timestamp&recvWindow=$recv"
    sig = hmac_sha256_hex(api_secret, qs)
    url = "$BINANCE_TESTNET_REST$endpoint?$qs&signature=$sig"
    headers = ["X-MBX-APIKEY" => api_key]

    try
        res = HTTP.post(url, headers)
        ok = res.status == 200
        ok || log_info("Order test rejected ($symbol $side): status=$(res.status) body=$(String(res.body))")
        return ok
    catch e
        log_info("Order test error ($symbol $side): $(typeof(e)) $e")
        return false
    end
end

function get_order_quantity(symbol::String)
    env_key = "IGGY_QTY_$(uppercase(symbol))"
    v = get(ENV, env_key, "")
    if v != ""
        try
            q = parse(Float64, v)
            q > 0 && return q
        catch
            # fall through to default
        end
    end
    return get(DEFAULT_QTY, uppercase(symbol), 0.001)
end

function place_testnet_order(symbol::String, side::String; quantity::Float64)
    # Places a REAL market order on Binance Spot TESTNET: /api/v3/order
    api_key = get(ENV, BINANCE_KEY_ENV, "")
    api_secret = get(ENV, BINANCE_SECRET_ENV, "")
    if api_key == "" || api_secret == ""
        log_info("Execution disabled: missing $BINANCE_KEY_ENV / $BINANCE_SECRET_ENV (load via env vars or .env).")
        return false
    end

    endpoint = "/api/v3/order"
    timestamp = Int64(floor(datetime2unix(now(Dates.UTC)) * 1000))
    recv = 5000
    # For MARKET orders on Spot: quantity is base asset quantity.
    qs = "symbol=$(uppercase(symbol))&side=$side&type=MARKET&quantity=$quantity&timestamp=$timestamp&recvWindow=$recv"
    sig = hmac_sha256_hex(api_secret, qs)
    url = "$BINANCE_TESTNET_REST$endpoint?$qs&signature=$sig"
    headers = ["X-MBX-APIKEY" => api_key]

    try
        res = HTTP.post(url, headers)
        if res.status == 200
            # Response JSON includes orderId, status, fills, etc.
            body = String(res.body)
            log_info("ORDER OK: $symbol $side qty=$quantity body=$body")
            return true
        else
            log_info("ORDER REJECTED: $symbol $side qty=$quantity status=$(res.status) body=$(String(res.body))")
            return false
        end
    catch e
        log_info("ORDER ERROR: $symbol $side qty=$quantity $(typeof(e)) $e")
        return false
    end
end

# ─────────────────────────────────────────
# INDICATORS
# ─────────────────────────────────────────
function ema(vals::Vector{Float64}, period::Int)
    α = 2.0 / (period + 1)
    e = vals[1]
    for v in vals[2:end]
        e = α * v + (1 - α) * e
    end
    return e
end

function macd_signal(prices::Vector{Float64})
    length(prices) < 26 && return 0.0
    fast = ema(prices[end-11:end],  12)
    slow = ema(prices[end-25:end],  26)
    return fast - slow
end

function atr(prices::Vector{Float64}, period::Int = 14)
    length(prices) < period + 1 && return 0.0
    tr = [abs(prices[i] - prices[i-1]) for i in 2:length(prices)]
    return mean(tr[max(1, end - period + 1):end])
end

# ─────────────────────────────────────────
# ADAPTIVE BIAS
# bias > 0  → recent trades in this symbol were profitable; favour longs
# bias < 0  → recent trades were lossy; suppress entries
# ─────────────────────────────────────────
function adaptive_bias(mem::AdaptiveMemory)
    isempty(mem.outcomes) && return 0.0
    n = min(10, length(mem.outcomes))
    return mean(mem.outcomes[end-n+1:end])
end

function record_outcome!(mem::AdaptiveMemory, pnl::Float64)
    push!(mem.pnl_history, pnl)
    push!(mem.outcomes, pnl > 0 ? 1.0 : (pnl < 0 ? -1.0 : 0.0))
    if length(mem.outcomes) > 50
        popfirst!(mem.outcomes)
        popfirst!(mem.pnl_history)
    end
    mem.cooldown = COOLDOWN_BARS
end

# ─────────────────────────────────────────
# RISK SIZING
# ─────────────────────────────────────────
position_size(balance, atr_val) =
    atr_val > 0 ? (balance * RISK_PER_TRADE) / atr_val : 0.0

# ─────────────────────────────────────────
# TRADE MANAGEMENT
# ─────────────────────────────────────────
function open_trade!(symbol::String, price::Float64, side::String,
                     atr_val::Float64, bar_idx::Int)
    size = position_size(1000.0, atr_val)
    tp   = side == "LONG" ? price + TP_MULT * atr_val : price - TP_MULT * atr_val
    sl   = side == "LONG" ? price - SL_MULT * atr_val : price + SL_MULT * atr_val

    open_pos[symbol] = OpenPosition(symbol, side, price, size, tp, sl, bar_idx)
    log_trade(@sprintf("OPEN %s %s @ %.4f | TP:%.4f SL:%.4f size:%.6f",
                       symbol, side, price, tp, sl, size))

    # Optional real execution (TESTNET).
    if is_execution_enabled()
        test_side = side == "LONG" ? "BUY" : "SELL"
        qty = get_order_quantity(symbol)
        ok = place_testnet_order(symbol, test_side; quantity=qty)
        ok || log_info("Live execution failed on OPEN ($symbol $test_side). Keeping position in simulation state.")
    end
end

function check_and_close!(symbol::String, price::Float64)
    !haskey(open_pos, symbol) && return

    pos = open_pos[symbol]
    hit_tp = pos.side == "LONG"  ? price >= pos.tp : price <= pos.tp
    hit_sl = pos.side == "LONG"  ? price <= pos.sl : price >= pos.sl

    (hit_tp || hit_sl) || return

    raw_pnl = pos.side == "LONG" ? (price - pos.entry) / pos.entry :
                                   (pos.entry - price) / pos.entry
    pnl     = raw_pnl * pos.size

    total_pnl[symbol] += pnl
    record_outcome!(adapt_mem[symbol], pnl)
    if pnl > 0
        successful_trades[] += 1
    elseif pnl < 0
        failed_trades[] += 1
    end
    save_runtime_state!()

    reason = hit_tp ? "TP" : "SL"
    tag    = pnl > 0 ? "✅ WIN" : "❌ LOSS"
    log_trade(@sprintf("CLOSE %s %s @ %.4f | %s pnl:%.6f cumulative:%.6f [%s]",
                       symbol, pos.side, price, reason, pnl, total_pnl[symbol], tag))
    maybe_notify_ready_for_real_account()

    # Optional real execution on close (place opposite side market order).
    if is_execution_enabled()
        close_side = pos.side == "LONG" ? "SELL" : "BUY"
        qty = get_order_quantity(symbol)
        ok = place_testnet_order(symbol, close_side; quantity=qty)
        ok || log_info("Live execution failed on CLOSE ($symbol $close_side).")
    end

    # If it was a loss, record *why* in the log so we can see the pattern
    if pnl < 0
        bias_at_entry = adaptive_bias(adapt_mem[symbol])
        log_info(@sprintf(
            "LOSS ANALYSIS %s: side=%s entry=%.4f exit=%.4f atr_implied=%.4f bias_at_entry=%.3f recent_outcomes=%s",
            symbol, pos.side, pos.entry, price,
            abs(pos.tp - pos.entry) / TP_MULT,
            bias_at_entry,
            string(adapt_mem[symbol].outcomes[max(1,end-4):end])
        ))
    end

    delete!(open_pos, symbol)
end

# ─────────────────────────────────────────
# SIGNAL + ANALYSIS
# ─────────────────────────────────────────
function analyze!(symbol::String, price::Float64)
    cache = price_cache[symbol]
    push!(cache, price)
    if length(cache) > KLINE_LIMIT
        popfirst!(cache)
    end
    bar_count[symbol] += 1

    # 1. Check open position first
    check_and_close!(symbol, price)

    # 2. Skip if already in a position
    haskey(open_pos, symbol) && return

    # 3. Skip warmup period
    length(cache) < WARMUP_BARS && return

    # 4. Respect cooldown
    mem = adapt_mem[symbol]
    if mem.cooldown > 0
        mem.cooldown -= 1
        return
    end

    # 5. Compute indicators
    a    = atr(cache)
    a == 0.0 && return

    # Skip if the market is too flat to trade reliably
    a / price < MIN_ATR_RATIO && return

    m    = macd_signal(cache)
    bias = adaptive_bias(mem)

    # Adaptive suppression: if recent losses dominate, reduce effective signal
    # (bias is negative after losses, which dampens or reverses entry signals)
    effective_signal = m / price * 1000 + bias   # normalise MACD by price

    # 6. Determine direction
    if effective_signal > SIGNAL_THRESH
        open_trade!(symbol, price, "LONG",  a, bar_count[symbol])
    elseif effective_signal < -SIGNAL_THRESH
        open_trade!(symbol, price, "SHORT", a, bar_count[symbol])
    end
end

# ─────────────────────────────────────────
# WEBSOCKET CONNECTOR
# ─────────────────────────────────────────
function connect(symbol::String)
    url = "$WS_BASE/$(lowercase(symbol))@kline_1m"
    println("🔗 CONNECTING $symbol")

    while true
        try
            HTTP.WebSockets.open(url) do ws
                println("✅ CONNECTED $symbol")
                for msg in ws
                    data  = JSON.parse(String(msg))
                    k     = data["k"]
                    is_closed = k["x"]          # true only on candle close
                    price = parse(Float64, k["c"])

                    # Print live tick but only run strategy on closed candles
                    @printf("📡 %s  %.4f\n", symbol, price)

                    # Always check TP/SL on every tick so exits are timely
                    check_and_close!(symbol, price)

                    # Run full analysis only on candle close to avoid noise entries
                    if is_closed
                        analyze!(symbol, price)
                    end
                end
            end
        catch e
            println("⚠️ RECONNECT $symbol | $(typeof(e))")
            sleep(2)
        end
    end
end

# ─────────────────────────────────────────
# CNS v5 RUNNER
# ─────────────────────────────────────────
function run_cns_v5(; symbols::Vector{String} = SYMBOLS)
    log_info("IGGY CNS v5.1 ADAPTIVE started")
    for s in symbols
        Threads.@spawn connect(s)
    end
    while true
        sleep(30)
        # Periodic status
        for s in symbols
            nb = length(price_cache[s])
            nc = haskey(open_pos, s) ? 1 : 0
            pnl = total_pnl[s]
            bias = adaptive_bias(adapt_mem[s])
            @printf("📊 %s  bars:%d  open:%d  pnl:%.4f  bias:%.2f\n",
                    s, nb, nc, pnl, bias)
        end
        @printf("📈 STATS wins:%d losses:%d winrate:%.2f%%\n",
                successful_trades[],
                failed_trades[],
                (successful_trades[] + failed_trades[]) > 0 ?
                    100 * successful_trades[] / (successful_trades[] + failed_trades[]) : 0.0)
        save_runtime_state!()
    end
end

# ─────────────────────────────────────────
# COMPATIBILITY LAYER (for bridge/executive)
# ─────────────────────────────────────────
mutable struct Capital
    balance :: Float64
    peak    :: Float64
    dd      :: Float64
end

mutable struct Strategy
    risk      :: Float64
    weights   :: Vector{Float64}
    threshold :: Float64
end

mutable struct Asset
    symbol     :: String
    price      :: Float64
    prev       :: Float64
    high       :: Float64
    low        :: Float64
    open       :: Float64
    volume     :: Float64
    closes     :: Vector{Float64}
    highs      :: Vector{Float64}
    lows       :: Vector{Float64}
    pressure   :: Float64
    trend      :: Float64
    atr_val    :: Float64
    macd_val   :: Float64
    regime     :: Int
    conf       :: Float64
    ema_fast   :: Float64
    ema_slow   :: Float64
    macd_fast  :: Float64
    macd_slow  :: Float64
    signal_line:: Float64
    macd_line  :: Float64
end

mutable struct Brain
    confidence :: Float64
    mode       :: Symbol
    cooldown   :: Int
end

mutable struct Position
    symbol :: String
    side   :: Int
    entry  :: Float64
    size   :: Float64
end

function get_klines_history(symbol::String, interval::String, limit::Int)
    base = "https://testnet.binance.vision"
    url  = "$base/api/v3/klines?symbol=$(uppercase(symbol))&interval=$interval&limit=$limit"
    try
        res  = HTTP.get(url)
        data = JSON.parse(String(res.body))
        o = Float64[]; h = Float64[]; l = Float64[]; c = Float64[]; v = Float64[]
        for k in data
            push!(o, parse(Float64, string(k[2])))
            push!(h, parse(Float64, string(k[3])))
            push!(l, parse(Float64, string(k[4])))
            push!(c, parse(Float64, string(k[5])))
            push!(v, parse(Float64, string(k[6])))
        end
        return o, h, l, c, v
    catch
        return nothing, nothing, nothing, nothing, nothing
    end
end

function update_asset!(a::Asset, o::Float64, h::Float64, l::Float64,
                       c::Float64, v::Float64)
    a.prev = a.price; a.price = c; a.open = o; a.high = h; a.low = l; a.volume = v
    push!(a.closes, c); push!(a.highs, h); push!(a.lows, l)
    if length(a.closes) > KLINE_LIMIT
        popfirst!(a.closes); popfirst!(a.highs); popfirst!(a.lows)
    end
    return a
end

function cns_main_loop_step(capital::Capital, strat::Strategy,
                            assets::Dict{String,Asset}, brains::Dict{String,Brain},
                            positions::Dict{String,Position}, kline_channel::Channel)
    isready(kline_channel) || return
    k   = take!(kline_channel)
    sym = get(k, "s", nothing)
    sym === nothing && return
    sym = uppercase(String(sym))
    o = parse(Float64, string(k["o"])); h = parse(Float64, string(k["h"]))
    l = parse(Float64, string(k["l"])); c = parse(Float64, string(k["c"]))
    v = parse(Float64, string(k["v"]))
    if !haskey(assets, sym)
        assets[sym] = Asset(sym, c, c, h, l, o, v, Float64[], Float64[], Float64[],
                            0.0, 0.0, 0.0, 0.0, 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    end
    update_asset!(assets[sym], o, h, l, c, v)
    capital.peak = max(capital.peak, capital.balance)
    capital.dd   = capital.peak > 0 ?
        max(0.0, (capital.peak - capital.balance) / capital.peak) : 0.0
end

# ─────────────────────────────────────────
# AUTO-RUN WHEN CALLED DIRECTLY
# ─────────────────────────────────────────
if abspath(PROGRAM_FILE) == @__FILE__
    run_cns_v5()
end
