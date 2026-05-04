using HTTP, JSON, Dates, Statistics, Printf, HTTP.WebSockets

# ─────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────
const SYMBOLS = ["BTCUSDT", "ETHUSDT", "SOLUSDT"]
const BASE_URL = "https://testnet.binance.vision"
const WS_BASE_URL = "wss://stream.binance.com:9443/stream"

const FEE = 0.0004
const SLIPPAGE = 0.0002
const EXTRA_COST = 0.0003
const MAX_DD = 0.10
const MAX_POSITIONS = 3 # Increased slightly

# Strategy Parameters
const MACD_FAST_PERIOD = 12
const MACD_SLOW_PERIOD = 26
const MACD_SIGNAL_PERIOD = 9
const ATR_PERIOD = 14
const ATR_MULTIPLIER_SL = 2.0
const ATR_MULTIPLIER_TP = 4.0
const RISK_PER_TRADE_PERCENT = 0.01
const KLINE_INTERVAL = "1m"
const KLINE_LIMIT = 200 # More history for better EMA stability

# IGGY CNS v5: Probabilistic Thresholds
const MIN_CONFLUENCE_SCORE = 0.65 # Threshold to take a trade (0.0 to 1.0)
const MOMENTUM_WEIGHT = 0.2
const PRESSURE_WEIGHT = 0.3
const MACD_WEIGHT = 0.3
const TREND_WEIGHT = 0.2

# ─────────────────────────────────────────
# STRUCTS
# ─────────────────────────────────────────
mutable struct Capital
    balance::Float64
    peak::Float64
    dd::Float64
end

mutable struct Brain
    confidence::Float64
    last_regime::Symbol
    transition_timer::Int
end

mutable struct Strategy
    weight::Float64
    pnl_history::Vector{Float64}
    expectancy::Float64
end

mutable struct Asset
    symbol::String
    price::Float64
    prev::Float64
    high::Float64
    low::Float64
    open::Float64
    volume::Float64
    
    close_history::Vector{Float64}
    high_history::Vector{Float64}
    low_history::Vector{Float64}
    
    vol::Float64
    pressure::Float64
    stability::Float64
    trend::Float64
    cooldown::Int
    vol_cluster::Float64
    
    # MACD indicators (Properly tracked)
    macd_fast_ema::Float64
    macd_slow_ema::Float64
    macd_signal_ema::Float64
    macd_line::Float64
    signal_line::Float64

    atr::Float64
end

mutable struct Position
    symbol::String
    side::Int
    entry::Float64
    size::Float64
    tp::Float64
    sl::Float64
    peak::Float64
    age::Int
end

# ─────────────────────────────────────────
# STABLE MATH HELPERS
# ─────────────────────────────────────────
# Fixed EMA to prevent drift: uses recursion only when necessary
function update_ema(current_val::Float64, prev_ema::Float64, period::Int)
    alpha = 2.0 / (period + 1.0)
    if prev_ema == 0.0
        return current_val # Seed with first value
    end
    return (current_val - prev_ema) * alpha + prev_ema
end

function calculate_atr(asset::Asset, period::Int)
    if length(asset.close_history) < period + 1; return 0.0; end
    
    tr_sum = 0.0
    for i in (length(asset.close_history) - period + 1):length(asset.close_history)
        h = asset.high_history[i]
        l = asset.low_history[i]
        pc = asset.close_history[i-1]
        tr = max(h - l, abs(h - pc), abs(l - pc))
        tr_sum += tr
    end
    return tr_sum / period
end

# ─────────────────────────────────────────
# DATA FETCHING
# ─────────────────────────────────────────
function get_klines_history(sym::String, interval::String, limit::Int)
    try
        res = HTTP.get("$BASE_URL/api/v3/klines?symbol=$sym&interval=$interval&limit=$limit")
        data = JSON.parse(String(res.body))
        
        o, h, l, c, v = Float64[], Float64[], Float64[], Float64[], Float64[]
        for k in data
            push!(o, parse(Float64, k[2]))
            push!(h, parse(Float64, k[3]))
            push!(l, parse(Float64, k[4]))
            push!(c, parse(Float64, k[5]))
            push!(v, parse(Float64, k[6]))
        end
        return o, h, l, c, v
    catch e
        println("Error fetching history: $e")
        return nothing, nothing, nothing, nothing, nothing
    end
end

# ─────────────────────────────────────────
# PERCEPTION (CNS v5 Upgrade)
# ─────────────────────────────────────────
function update_asset!(a::Asset, new_o::Float64, new_h::Float64, new_l::Float64, new_c::Float64, new_v::Float64)
    a.prev = a.price == 0 ? new_c : a.price
    a.price = new_c
    a.high, a.low, a.open, a.volume = new_h, new_l, new_o, new_v

    push!(a.close_history, new_c)
    push!(a.high_history, new_h)
    push!(a.low_history, new_l)

    if length(a.close_history) > KLINE_LIMIT
        popfirst!(a.close_history); popfirst!(a.high_history); popfirst!(a.low_history)
    end

    # Basic stats
    a.vol = abs(new_c - a.prev) / a.prev
    a.vol_cluster = update_ema(a.vol, a.vol_cluster, 50)
    
    # Pressure & Trend
    a.pressure = update_ema(sign(new_c - a.prev) * a.vol, a.pressure, 20)
    a.trend = update_ema(sign(new_c - a.prev), a.trend, 50)
    a.stability = exp(-a.vol_cluster * 2000)

    # MACD (Stable Implementation)
    a.macd_fast_ema = update_ema(new_c, a.macd_fast_ema, MACD_FAST_PERIOD)
    a.macd_slow_ema = update_ema(new_c, a.macd_slow_ema, MACD_SLOW_PERIOD)
    a.macd_line = a.macd_fast_ema - a.macd_slow_ema
    a.signal_line = update_ema(a.macd_line, a.signal_line, MACD_SIGNAL_PERIOD)

    # ATR
    a.atr = calculate_atr(a, ATR_PERIOD)
end

# ─────────────────────────────────────────
# SIGNAL ENGINE (CNS v5 PROBABILISTIC)
# ─────────────────────────────────────────
function generate_signal(a, brain, strat)
    if a.cooldown > 0; return 0, 0.0; end

    # 1. Momentum Component
    mom_score = sign(a.price - a.prev) * MOMENTUM_WEIGHT
    
    # 2. Pressure Component
    pres_score = sign(a.pressure) * PRESSURE_WEIGHT * (abs(a.pressure) / (a.vol_cluster + 1e-9))
    pres_score = clamp(pres_score, -PRESSURE_WEIGHT, PRESSURE_WEIGHT)

    # 3. MACD Component
    macd_diff = a.macd_line - a.signal_line
    macd_score = sign(macd_diff) * MACD_WEIGHT * clamp(abs(macd_diff) / (a.price * 0.001), 0, 1)

    # 4. Trend Component
    trend_score = sign(a.trend) * TREND_WEIGHT * abs(a.trend)

    # Calculate Confluence
    total_score = mom_score + pres_score + macd_score + trend_score
    
    # Adjust threshold based on stability (be pickier in volatile markets)
    dynamic_threshold = MIN_CONFLUENCE_SCORE * (1.2 - a.stability)
    dynamic_threshold = clamp(dynamic_threshold, 0.4, 0.8)

    confidence_factor = brain.confidence * strat.weight
    final_edge = abs(total_score) * confidence_factor

    if final_edge > dynamic_threshold
        side = total_score > 0 ? 1 : -1
        return side, final_edge
    end

    return 0, final_edge
end

# ─────────────────────────────────────────
# RISK & EXECUTION
# ─────────────────────────────────────────
function position_size(capital, a)
    if a.atr == 0.0; return 0.0; end
    risk_amt = capital.balance * RISK_PER_TRADE_PERCENT
    sl_dist = a.atr * ATR_MULTIPLIER_SL
    size = risk_amt / sl_dist
    return clamp(size, 0.0001, 0.1) 
end

function open_position(a, signal, capital)
    size = position_size(capital, a)
    if size == 0.0; return nothing; end
    tp = a.price * (1 + signal * a.atr * ATR_MULTIPLIER_TP / a.price)
    sl = a.price * (1 - signal * a.atr * ATR_MULTIPLIER_SL / a.price)
    return Position(a.symbol, signal, a.price, size, tp, sl, 0.0, 0)
end

function close_trade!(pos, pnl, capital, brain, strat, reason, assets)
    net = (pnl - FEE - SLIPPAGE) * pos.size
    capital.balance += net
    capital.peak = max(capital.peak, capital.balance)
    capital.dd = (capital.peak - capital.balance) / capital.peak
    
    if net < 0
        assets[pos.symbol].cooldown = 15
    end

    brain.confidence = clamp(brain.confidence + (net > 0 ? 0.02 : -0.05), 0.1, 1.2)
    push!(strat.pnl_history, net)
    strat.expectancy = isempty(strat.pnl_history) ? 0.0 : mean(strat.pnl_history[max(1,end-20):end])
    strat.weight = clamp(1.0 + strat.expectancy * 10, 0.5, 2.0)

    println("\n📤 EXIT | $(pos.symbol) | $reason | PnL: $(round(net, digits=4)) | Bal: $(round(capital.balance, digits=2))")
    return true
end

function update_position!(pos, a, capital, brain, strat, assets)
    pos.age += 1
    pnl = (a.price - pos.entry) / pos.entry * pos.side
    pos.peak = max(pos.peak, pnl)

    # ATR Stop
    if pnl < -(a.atr * ATR_MULTIPLIER_SL / pos.entry)
        return close_trade!(pos, pnl, capital, brain, strat, :STOP_ATR, assets)
    end
    # Trailing
    if pos.peak > 0.005 && pnl < pos.peak * 0.7
        return close_trade!(pos, pnl, capital, brain, strat, :TRAILING, assets)
    end
    # Take Profit
    if (pos.side == 1 && a.price >= pos.tp) || (pos.side == -1 && a.price <= pos.tp)
        return close_trade!(pos, pnl, capital, brain, strat, :TAKE_PROFIT, assets)
    end
    return false
end

# ─────────────────────────────────────────
# MAIN LOOP
# ─────────────────────────────────────────
function run_iggy()
    capital = Capital(1000.0, 1000.0, 0.0)
    strat = Strategy(1.0, Float64[], 0.0)
    assets, brains = Dict{String,Asset}(), Dict{String,Brain}()

    println("📥 Initializing History...")
    for s in SYMBOLS
        o, h, l, c, v = get_klines_history(s, KLINE_INTERVAL, KLINE_LIMIT)
        if c !== nothing
            assets[s] = Asset(s, c[end], c[end], h[end], l[end], o[end], v[end], c, h, l, 0.0, 0.0, 0.0, 0.0, 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
            # Warm up indicators
            for i in 1:length(c)
                update_asset!(assets[s], o[i], h[i], l[i], c[i], v[i])
            end
        end
        brains[s] = Brain(1.0, :TREND, 0)
    end

    positions = Dict{String,Position}()
    kline_channel = Channel(100)

    println("🚀 IGGY CNS v5 ACTIVE - Probabilistic Engine")
    
    stream_names = [lowercase(s) * "@kline_" * KLINE_INTERVAL for s in SYMBOLS]
    websocket_url = WS_BASE_URL * "?streams=" * join(stream_names, "/")

    @async begin
        try
            HTTP.WebSockets.open(websocket_url) do ws
                for msg in ws
                    data = JSON.parse(String(msg))
                    if haskey(data, "data") && haskey(data["data"], "k")
                        k = data["data"]["k"]
                        if k["x"]; put!(kline_channel, k); end
                    end
                end
            end
        catch e; println("\nWebSocket Error: $e"); end
    end

    while capital.dd < MAX_DD
        if isready(kline_channel)
            k = take!(kline_channel)
            sym = k["s"]
            a = assets[sym]
            
            update_asset!(a, parse(Float64, k["o"]), parse(Float64, k["h"]), parse(Float64, k["l"]), parse(Float64, k["c"]), parse(Float64, k["v"]))
            
            # Check Positions
            for (ps, p) in copy(positions)
                if ps == sym && update_position!(p, a, capital, brains[ps], strat, assets)
                    delete!(positions, ps)
                end
            end

            # Check Entry
            if length(positions) < MAX_POSITIONS && !haskey(positions, sym)
                side, edge = generate_signal(a, brains[sym], strat)
                if side != 0
                    pos = open_position(a, side, capital)
                    if pos !== nothing
                        positions[sym] = pos
                        println("\n📥 ENTRY | $sym | $(side==1 ? "LONG" : "SHORT") | Edge: $(round(edge, digits=3))")
                    end
                end
            end

            @printf("💰 %.2f | DD: %.2f%% | Active: %d | %s: %.2f\r", 
                capital.balance, capital.dd*100, length(positions), sym, a.price)
        else
            yield()
        end
    end
    println("\n🛑 MAX DRAWDOWN REACHED")
end

run_iggy()
