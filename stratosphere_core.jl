# ==============================================================================
# IGGY v17.4 — STABLE QUANT ENGINE (REPAIRED)
# ==============================================================================




# New line
using HTTP, JSON, Dates, Random, Statistics, Printf, Dates, Logging
using CSV, DataFrames

# ─────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────

const BASE_URL = "https://api.binance.com"
const MAX_DRAWDOWN = -0.4
const WARMUP = 40
const POSITION_SIZE = 5.0
const HOLD_TIME = 30  # Seconds to hold before checking exit

# ─────────────────────────────────────────
# STATE
# ─────────────────────────────────────────

mutable struct IGGY
    equity::Float64
    peak_equity::Float64
    w_trend::Float64
    w_range::Float64
    w_vol::Float64
    returns::Vector{Float64}
end

# ─────────────────────────────────────────
# PRICE FEED (Added Error Handling)
# ─────────────────────────────────────────

function get_price(symbol)
    max_retries = 3
    for i in 1:max_retries
        try
            url = "$BASE_URL/api/v3/ticker/price?symbol=$symbol"
            res = HTTP.get(url, readtimeout=5, connect_timeout=5)
            data = JSON.parse(String(res.body))
            return parse(Float64, data["price"])
        catch e
            if i == max_retries
                @warn "Final attempt failed for $symbol: $e"
                return 0.0
            end
            sleep(1 * i) # Wait longer with each failure
        end
    end
    return 0.0
end

# ─────────────────────────────────────────
# QUANT FEATURES
# ─────────────────────────────────────────

function moving_avg(p, n)
    length(p) < n ? mean(p) : mean(p[end-n+1:end])
end

function volatility(p, n)
    length(p) < n ? 0.0 : std(diff(p[end-n+1:end]))
end

function momentum(p, n)
    length(p) <= n ? 0.0 : p[end] - p[end-n]
end

# ─────────────────────────────────────────
# STRATEGIES
# ─────────────────────────────────────────

function trend_strategy(p)
    fast = moving_avg(p, 5)
    slow = moving_avg(p, 20)
    return fast > slow ? 1 : -1
end

function range_strategy(p)
    μ = moving_avg(p, 20)
    return p[end] > μ ? -1 : 1 # Mean reversion
end

function vol_strategy(p)
    vol = volatility(p, 20)
    mom = momentum(p, 5)
    if vol < 0.0005
        return 0
    elseif mom > 0
        return 1
    else
        return -1
    end
end

# ─────────────────────────────────────────
# DECISION ENGINE
# ─────────────────────────────────────────

function decide(core, p)
    t = trend_strategy(p)
    r = range_strategy(p)
    v = vol_strategy(p)

    score = (core.w_trend * t) + (core.w_range * r) + (core.w_vol * v)

    # Ignore weak/noise signals
    return abs(score) < 0.40 ? 0 : Int(sign(score))
end

# Inside stratosphere_core.jl
function execute(entry, exit, signal)
    ret = (exit - entry) / entry
    # Subtract 0.1% for entry and 0.1% for exit (standard Binance fees)
    actual_pnl = (ret * signal * POSITION_SIZE) - 0.002 
    return actual_pnl
end
# ─────────────────────────────────────────
# SAFE LEARNING (No NaN/Div0)
# ─────────────────────────────────────────



function update_weights!(core, pnl)
    # 1. Protection against bad data
    if isnan(pnl) || isinf(pnl); return end

    # 2. Append new PNL to current session memory
    push!(core.returns, pnl)
    
    # 3. "Log-Learning": If session memory is low, try to fill from CSV
    if length(core.returns) < 10 && isfile("iggy_trade_log.csv")
        try
            df = CSV.read("iggy_trade_log.csv", DataFrame)
            if !isempty(df) && "pnl" in names(df)
                # Take the last 50 historical PNLs from the log
                historical_pnls = df.pnl[max(1, end-49):end]
                # Merge historical data with current session data
                core.returns = vcat(historical_pnls, core.returns)
            end
        catch e
            @warn "Could not read logs for learning: $e"
        end
    end

    # Keep memory manageable (rolling window of 100)
    if length(core.returns) > 100
        core.returns = core.returns[end-99:end]
    end

    # 4. Math Check (Minimum samples for Sharpe)
    length(core.returns) < 10 && return

    μ = mean(core.returns)
    σ = std(core.returns)

    # Avoid division by zero
    if σ < 1e-8; return end

    # Sharpe-based adjustment
    sharpe = clamp(μ / σ, -2.0, 2.0)
    lr = 0.03 # Learning Rate

    # Update weights
    core.w_trend += lr * sharpe
    core.w_range += lr * sharpe
    core.w_vol   += lr * sharpe

    # 5. Normalization (Crucial for stability)
    s = abs(core.w_trend) + abs(core.w_range) + abs(core.w_vol)

    if s < 1e-8
        core.w_trend, core.w_range, core.w_vol = 0.33, 0.33, 0.34
    else
        core.w_trend /= s
        core.w_range /= s
        core.w_vol   /= s
    end
end
# ─────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────


function log_trade(signal, entry, exit, pnl, eq, weights)
    file_path = "iggy_trade_log.csv"
    
    # Create header if file doesn't exist
    if !isfile(file_path)
        open(file_path, "w") do f
            write(f, "timestamp,signal,entry,exit,pnl,equity,w1,w2,w3\n")
        end
    end

    # Append the trade data
    open(file_path, "a") do f
        timestamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
        weights_str = join(round.(weights, digits=4), ",")
        write(f, "$timestamp,$signal,$entry,$exit,$pnl,$eq,$weights_str\n")
    end
end


# ─────────────────────────────────────────
# RUNTIME
# ─────────────────────────────────────────

function run_iggy()
    # Initialize IGGY with start equity and initial weights
    core = IGGY(1.0, 1.0, 0.33, 0.33, 0.34, Float64[])
    symbol = "BTCUSDT"
    prices = Float64[]

    println(">>> IGGY v17.4 STABLE QUANT ENGINE ONLINE")

    while true
        # 1. Risk Check: Monitoring Drawdown
        core.peak_equity = max(core.peak_equity, core.equity)
        dd = (core.equity - core.peak_equity) / core.peak_equity
        if dd < MAX_DRAWDOWN
            println("🛑 STOPPED — DRAWDOWN LIMIT ($MAX_DRAWDOWN) REACHED")
            break
        end

        # 2. Data Fetch: Get current price
        price = get_price(symbol)
        if price <= 0.0
            println("⚠️ Network glitch, retrying...")
            sleep(2)
            continue 
        end
        
        push!(prices, price)
        length(prices) > 120 && popfirst!(prices)

        # 3. Warmup Phase
        if length(prices) < WARMUP
            println("⏳ WARMUP $(length(prices))/$WARMUP")
            sleep(1)
            continue
        end

        println("💓 Heartbeat: $(Dates.now()) | Price: $price")
        flush(stdout)

        # 4. Decision Engine
        signal = decide(core, prices)
        if signal == 0
            sleep(1)
            continue
        end

        # 5. Trade Execution
        entry = price
        println("🚀 SIGNAL: $signal | ENTRY: $entry")
        sleep(HOLD_TIME)

        # 6. Exit & Results
        exit = get_price(symbol)
        if exit <= 0.0; exit = entry end # Safety fallback
        
        pnl = execute(entry, exit, signal)
        
        # 7. State Update & Learning
        core.equity += pnl
        update_weights!(core, pnl) # Ensure the 'tail' fix is in this function!

        # 8. Logging & Telemetry
        weights_array = [core.w_trend, core.w_range, core.w_vol]
        log_trade(signal, entry, exit, pnl, core.equity, weights_array)

        @printf("📊 EQ: %.4f | PNL: %.4f | W: %.2f, %.2f, %.2f\n", 
                core.equity, pnl, core.w_trend, core.w_range, core.w_vol)
    end
end
run_iggy()