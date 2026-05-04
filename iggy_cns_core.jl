using HTTP, JSON, Dates, Statistics, Printf, HTTP.WebSockets

# ─────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────
const SYMBOLS = ["BTCUSDT", "ETHUSDT", "SOLUSDT"]
const BASE_URL = "https://testnet.binance.vision"

# FIX 1: correct testnet websocket
const WS_BASE_URL = "wss://testnet.binance.vision/ws"

const FEE = 0.0004
const SLIPPAGE = 0.0002
const EXTRA_COST = 0.0003
const MAX_DD = 0.10
const MAX_POSITIONS = 3

# Strategy Parameters
const MACD_FAST_PERIOD = 12
const MACD_SLOW_PERIOD = 26
const MACD_SIGNAL_PERIOD = 9
const ATR_PERIOD = 14
const ATR_MULTIPLIER_SL = 2.0
const ATR_MULTIPLIER_TP = 4.0
const RISK_PER_TRADE_PERCENT = 0.01
const KLINE_INTERVAL = "1m"
const KLINE_LIMIT = 200

# FIX 2: more realistic for live trading
const MIN_CONFLUENCE_SCORE = 0.40

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
# EMA
# ─────────────────────────────────────────
function update_ema(current::Float64, prev::Float64, period::Int)
    alpha = 2.0 / (period + 1.0)
    if prev == 0.0
        return current
    end
    return (current - prev) * alpha + prev
end

# ─────────────────────────────────────────
# ATR
# ─────────────────────────────────────────
function calculate_atr(asset::Asset, period::Int)
    if length(asset.close_history) < period + 1
        return 0.0
    end

    tr_sum = 0.0
    for i in (length(asset.close_history)-period+1):length(asset.close_history)
        h = asset.high_history[i]
        l = asset.low_history[i]
        pc = asset.close_history[i-1]
        tr_sum += max(h - l, abs(h - pc), abs(l - pc))
    end
    return tr_sum / period
end

# ─────────────────────────────────────────
# DATA
# ─────────────────────────────────────────
function get_klines_history(sym, interval, limit)
    res = HTTP.get("$BASE_URL/api/v3/klines?symbol=$sym&interval=$interval&limit=$limit")
    data = JSON.parse(String(res.body))

    o,h,l,c,v = Float64[],Float64[],Float64[],Float64[],Float64[]
    for k in data
        push!(o, parse(Float64,k[2]))
        push!(h, parse(Float64,k[3]))
        push!(l, parse(Float64,k[4]))
        push!(c, parse(Float64,k[5]))
        push!(v, parse(Float64,k[6]))
    end
    return o,h,l,c,v
end

# ─────────────────────────────────────────
# UPDATE ASSET
# ─────────────────────────────────────────
function update_asset!(a, o,h,l,c,v)
    a.prev = a.price == 0 ? c : a.price
    a.price = c
    a.high,a.low,a.open,a.volume = h,l,o,v

    push!(a.close_history,c)
    push!(a.high_history,h)
    push!(a.low_history,l)

    if length(a.close_history) > KLINE_LIMIT
        popfirst!(a.close_history)
        popfirst!(a.high_history)
        popfirst!(a.low_history)
    end

    a.vol = abs(c - a.prev) / (a.prev + 1e-9)
    a.pressure = update_ema(sign(c - a.prev) * a.vol, a.pressure, 20)
    a.trend = update_ema(sign(c - a.prev), a.trend, 50)

    a.macd_fast_ema = update_ema(c, a.macd_fast_ema, MACD_FAST_PERIOD)
    a.macd_slow_ema = update_ema(c, a.macd_slow_ema, MACD_SLOW_PERIOD)

    a.macd_line = a.macd_fast_ema - a.macd_slow_ema
    a.signal_line = update_ema(a.macd_line, a.signal_line, MACD_SIGNAL_PERIOD)

    a.atr = calculate_atr(a, ATR_PERIOD)
end

# ─────────────────────────────────────────
# SIGNAL
# ─────────────────────────────────────────
function generate_signal(a, brain, strat)

    if a.cooldown > 0
        return 0,0.0
    end

    mom = sign(a.price - a.prev) * MOMENTUM_WEIGHT
    pres = sign(a.pressure) * PRESSURE_WEIGHT
    macd = sign(a.macd_line - a.signal_line) * MACD_WEIGHT
    trend = sign(a.trend) * TREND_WEIGHT

    total = mom + pres + macd + trend
    edge = abs(total)

    if edge > MIN_CONFLUENCE_SCORE
        return total > 0 ? 1 : -1, edge
    end

    return 0, edge
end

# ─────────────────────────────────────────
# POSITION
# ─────────────────────────────────────────
function position_size(cap, a)
    if a.atr == 0.0
        return 0.0
    end
    return clamp(cap.balance * 0.01 / a.atr, 0.0001, 0.1)
end

function open_position(a, signal, cap)
    size = position_size(cap, a)
    if size == 0.0
        return nothing
    end

    tp = a.price * (1 + signal * 0.02)
    sl = a.price * (1 - signal * 0.01)

    return Position(a.symbol, signal, a.price, size, tp, sl, 0.0, 0)
end

# ─────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────
function run_iggy()

    cap = Capital(1000.0,1000.0,0.0)
    strat = Strategy(1.0,Float64[],0.0)

    assets = Dict{String,Asset}()
    brains = Dict{String,Brain}()

    println("📥 Initializing...")

    for s in SYMBOLS
        o,h,l,c,v = get_klines_history(s,KLINE_INTERVAL,KLINE_LIMIT)

        a = Asset(s,c[end],c[end],h[end],l[end],o[end],v[end],
        c,h,l,
        0.0,0.0,0.0,0.0,0,
        0.0,
        0.0,0.0,0.0,0.0,0.0)

        # FIX 3: warmup EMA properly
        for i in 1:length(c)
            update_asset!(a,o[i],h[i],l[i],c[i],v[i])
        end

        assets[s] = a
        brains[s] = Brain(1.0,:TREND,0)
    end

    positions = Dict{String,Position}()
    channel = Channel(100)

    println("🚀 IGGY CNS FIXED ACTIVE")

    streams = join([lowercase(s)*"@kline_"*KLINE_INTERVAL for s in SYMBOLS],"/")
    ws_url = WS_BASE_URL * "?streams=" * streams

    @async begin
        HTTP.WebSockets.open(ws_url) do ws
            for msg in ws
                d = JSON.parse(String(msg))
                if haskey(d,"data")
                    put!(channel,d["data"]["k"]) # FIX 4: no blocking filter
                end
            end
        end
    end

    while cap.dd < MAX_DD

        if isready(channel)

            k = take!(channel)
            s = k["s"]
            a = assets[s]

            update_asset!(a,
                parse(Float64,k["o"]),
                parse(Float64,k["h"]),
                parse(Float64,k["l"]),
                parse(Float64,k["c"]),
                parse(Float64,k["v"])
            )

            for (ps,p) in copy(positions)
                if ps == s
                    delete!(positions,ps)
                end
            end

            if length(positions) < MAX_POSITIONS && !haskey(positions,s)
                sig,edge = generate_signal(a,brains[s],strat)
                if sig != 0
                    pos = open_position(a,sig,cap)
                    if pos !== nothing
                        positions[s] = pos
                        println("\nENTRY $s $(sig==1 ? "LONG" : "SHORT") edge=$edge")
                    end
                end
            end

            @printf("💰 %.2f | DD %.2f%% | POS %d | %s %.2f\n",
                cap.balance,cap.dd*100,length(positions),s,a.price)

        else
            # FIX 5: heartbeat so it doesn't look frozen
            @printf("⏳ waiting data... positions=%d\r", length(positions))
            sleep(0.5)
        end
    end

    println("STOPPED - MAX DD")
end

run_iggy()