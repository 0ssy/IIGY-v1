# ==============================================================================
# IGGY v19 — ADAPTIVE REGIME ENGINE
# ==============================================================================

using HTTP, JSON, Dates, Statistics, Printf, Logging, CSV, DataFrames

# ─────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────

const BASE_URL = "https://api.binance.com"
const MAX_DRAWDOWN = -0.4
const WARMUP = 60
const POSITION_SIZE = 5.0
const TRADE_COOLDOWN = 30  # seconds

# ─────────────────────────────────────────
# STATE
# ─────────────────────────────────────────

mutable struct IGGY
    equity::Float64
    peak_equity::Float64
    w_trend::Float64
    w_range::Float64
    w_vol::Float64
    returns_trend::Vector{Float64}
    returns_range::Vector{Float64}
    last_trade_time::Int64
end

# ─────────────────────────────────────────
# API
# ─────────────────────────────────────────

function get_price(symbol)
    try
        url = "$BASE_URL/api/v3/ticker/price?symbol=$symbol"
        res = HTTP.get(url)
        data = JSON.parse(String(res.body))
        return parse(Float64, data["price"])
    catch
        return 0.0
    end
end

# ─────────────────────────────────────────
# FEATURES
# ─────────────────────────────────────────

moving_avg(p, n) = length(p) < n ? mean(p) : mean(p[end-n+1:end])
volatility(p, n) = length(p) < n ? 0.0 : std(diff(p[end-n+1:end]))
momentum(p, n) = length(p) <= n ? 0.0 : p[end] - p[end-n]

function atr(p, n=14)
    length(p) < n+1 && return 0.0
    return mean(abs.(diff(p[end-n:end])))
end

# ─────────────────────────────────────────
# REGIME + MTF
# ─────────────────────────────────────────

function get_regime(p)
    fast = moving_avg(p, 20)
    slow = moving_avg(p, 50)
    strength = abs(fast - slow) / slow

    return strength > 0.0015 ? :TREND : :RANGE
end

function mtf_trend(p)
    short = moving_avg(p, 20)
    long = moving_avg(p, 100)
    return short > long ? 1 : -1
end

# ─────────────────────────────────────────
# STRATEGIES
# ─────────────────────────────────────────

trend_strategy(p) = moving_avg(p,5) > moving_avg(p,20) ? 1 : -1
range_strategy(p) = p[end] > moving_avg(p,20) ? -1 : 1

function vol_strategy(p)
    vol = volatility(p, 20)
    mom = momentum(p, 5)
    vol < 0.0005 && return 0
    return mom > 0 ? 1 : -1
end

# ─────────────────────────────────────────
# DECISION ENGINE (FIXED)
# ─────────────────────────────────────────

function decide(core, p)
    regime = get_regime(p)
    mtf = mtf_trend(p)

    t = trend_strategy(p)
    r = range_strategy(p)
    v = vol_strategy(p)

    if regime == :TREND
        score = (core.w_trend * t) + (core.w_vol * v)
        tag = :TREND
    else
        score = (core.w_range * r)
        tag = :RANGE
    end

    # MTF filter
    if score > 0 && mtf < 0
        return 0, tag
    elseif score < 0 && mtf > 0
        return 0, tag
    end

    return abs(score) < 0.4 ? 0 : Int(sign(score)), tag
end

# ─────────────────────────────────────────
# EXECUTION (ATR-BASED)
# ─────────────────────────────────────────

function execute_trade(signal, entry, prices)
    a = atr(prices)

    stop = signal == 1 ? entry - (a * 1.5) : entry + (a * 1.5)
    take = signal == 1 ? entry + (a * 2.5) : entry - (a * 2.5)

    exit = entry

    for i in 1:60
        sleep(1)
        px = get_price("BTCUSDT")
        px <= 0 && continue

        # breakeven
        if signal == 1 && px - entry > a * 0.8
            stop = entry
        elseif signal == -1 && entry - px > a * 0.8
            stop = entry
        end

        if signal == 1 && (px <= stop || px >= take)
            exit = px
            break
        elseif signal == -1 && (px >= stop || px <= take)
            exit = px
            break
        end

        exit = px
    end

    ret = (exit - entry) / entry
    pnl = (ret * signal * POSITION_SIZE) - 0.002
    return pnl
end

# ─────────────────────────────────────────
# TRUE LEARNING (PER-STRATEGY)
# ─────────────────────────────────────────

function update_weights!(core, pnl, tag)
    if tag == :TREND
        push!(core.returns_trend, pnl)
    else
        push!(core.returns_range, pnl)
    end

    function sharpe(x)
        length(x) < 10 && return 0.0
        σ = std(x)
        σ < 1e-8 && return 0.0
        return clamp(mean(x)/σ, -2, 2)
    end

    s_trend = sharpe(core.returns_trend)
    s_range = sharpe(core.returns_range)

    lr = 0.05

    core.w_trend += lr * s_trend
    core.w_range += lr * s_range
    core.w_vol   += lr * s_trend

    # normalize
    s = abs(core.w_trend) + abs(core.w_range) + abs(core.w_vol)
    core.w_trend /= s
    core.w_range /= s
    core.w_vol   /= s
end

# ─────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────

function log_trade(signal, entry, pnl, eq, tag)
    file = "iggy_v19_log.csv"
    if !isfile(file)
        open(file,"w") do f
            write(f,"time,signal,entry,pnl,equity,tag\n")
        end
    end
    open(file,"a") do f
        write(f,"$(now()),$signal,$entry,$pnl,$eq,$tag\n")
    end
end

# ─────────────────────────────────────────
# MAIN LOOP
# ─────────────────────────────────────────

function run_iggy()
    core = IGGY(1.0,1.0,0.33,0.33,0.34,Float64[],Float64[],0)
    prices = Float64[]
    symbol = "BTCUSDT"

    println("🚀 IGGY v19 ONLINE")

    while true
        price = get_price(symbol)
        price <= 0 && continue

        push!(prices, price)
        length(prices) > 200 && popfirst!(prices)

        if length(prices) < WARMUP
            println("⏳ WARMUP $(length(prices))/$WARMUP")
            sleep(1)
            continue
        end

        # drawdown
        core.peak_equity = max(core.peak_equity, core.equity)
        dd = (core.equity - core.peak_equity) / core.peak_equity
        dd < MAX_DRAWDOWN && break

        # cooldown
        if time() - core.last_trade_time < TRADE_COOLDOWN
            sleep(1)
            continue
        end

        signal, tag = decide(core, prices)
        signal == 0 && continue

        entry = price
        println("🚀 $tag TRADE | SIGNAL: $signal @ $entry")

        pnl = execute_trade(signal, entry, prices)

        core.equity += pnl
        core.last_trade_time = time()

        update_weights!(core, pnl, tag)
        log_trade(signal, entry, pnl, core.equity, tag)

        @printf("📊 EQ: %.4f | PNL: %.4f | W: %.2f %.2f %.2f\n",
            core.equity, pnl, core.w_trend, core.w_range, core.w_vol)
    end
end

run_iggy()