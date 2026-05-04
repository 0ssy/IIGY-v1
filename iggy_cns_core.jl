using HTTP, JSON, Dates, Statistics, Printf, HTTP.WebSockets

# ─────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────
const SYMBOLS = ["BTCUSDT", "ETHUSDT", "SOLUSDT"]

# TESTNET REST (VALID)
const BASE_URL = "https://testnet.binance.vision"

# MAINNET WS (REQUIRED FOR STABILITY)
const WS_BASE = "wss://stream.binance.com:9443/ws/"

const MAX_POSITIONS = 3
const KLINE_INTERVAL = "1m"
const KLINE_LIMIT = 200
const MIN_CONFLUENCE_SCORE = 0.40

const MOMENTUM_WEIGHT = 0.2
const PRESSURE_WEIGHT = 0.3
const MACD_WEIGHT = 0.3
const TREND_WEIGHT = 0.2

# ─────────────────────────────────────────
# UTILS
# ─────────────────────────────────────────
tofloat(x) = parse(Float64, string(x))

# ─────────────────────────────────────────
# STRUCTS
# ─────────────────────────────────────────
mutable struct Asset
    symbol::String
    price::Float64
    prev::Float64

    pressure::Float64
    trend::Float64

    macd_fast::Float64
    macd_slow::Float64
    macd_line::Float64
    signal_line::Float64
end

mutable struct Position
    symbol::String
    side::Int
    entry::Float64
    size::Float64
end

mutable struct Capital
    balance::Float64
end

# ─────────────────────────────────────────
# EMA
# ─────────────────────────────────────────
function ema(cur, prev, period)
    α = 2.0 / (period + 1)
    prev == 0.0 && return cur
    return (cur - prev) * α + prev
end

# ─────────────────────────────────────────
# TESTNET REST DATA
# ─────────────────────────────────────────
function get_klines(sym)
    url = "$BASE_URL/api/v3/klines?symbol=$sym&interval=$KLINE_INTERVAL&limit=$KLINE_LIMIT"
    res = HTTP.get(url)
    data = JSON.parse(String(res.body))

    c = [tofloat(k[5]) for k in data]
    return c
end

# ─────────────────────────────────────────
# BUILD ASSET
# ─────────────────────────────────────────
function build_asset(sym, closes)
    Asset(sym, closes[end], closes[end], 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
end

# ─────────────────────────────────────────
# UPDATE ASSET
# ─────────────────────────────────────────
function update_asset!(a, price)

    a.prev = a.price
    a.price = price

    delta = a.prev == 0.0 ? 0.0 : (price - a.prev)

    a.pressure = ema(sign(delta), a.pressure, 20)
    a.trend = ema(sign(delta), a.trend, 50)

    a.macd_fast = ema(price, a.macd_fast, 12)
    a.macd_slow = ema(price, a.macd_slow, 26)

    a.macd_line = a.macd_fast - a.macd_slow
    a.signal_line = ema(a.macd_line, a.signal_line, 9)
end

# ─────────────────────────────────────────
# SIGNAL ENGINE
# ─────────────────────────────────────────
function signal(a)

    mom = sign(a.price - a.prev) * MOMENTUM_WEIGHT
    pres = sign(a.pressure) * PRESSURE_WEIGHT
    macd = sign(a.macd_line - a.signal_line) * MACD_WEIGHT
    trend = sign(a.trend) * TREND_WEIGHT

    score = mom + pres + macd + trend
    edge = abs(score)

    edge > MIN_CONFLUENCE_SCORE ? (score > 0 ? (1, edge) : (-1, edge)) : (0, edge)
end

# ─────────────────────────────────────────
# WS URL
# ─────────────────────────────────────────
ws_url(sym) = WS_BASE * lowercase(sym) * "@kline_" * KLINE_INTERVAL

# ─────────────────────────────────────────
# MAIN ENGINE
# ─────────────────────────────────────────
function run()

    println("📥 Loading TESTNET history...")

    assets = Dict{String,Asset}()

    for s in SYMBOLS
        closes = get_klines(s)
        assets[s] = build_asset(s, closes)
    end

    channel = Channel{Any}(200)
    positions = Dict{String,Position}()

    println("🚀 IGGY ENGINE STARTED (TESTNET + MAINNET WS)")

    # ─────────────────────────────────────────
    # WS STREAMS (FIXED JULIA PATTERN)
    # ─────────────────────────────────────────
    for s in SYMBOLS
        @async begin
            while true
                try
                    HTTP.WebSockets.open(ws_url(s)) do ws
                        println("🔗 Connected: $s")

                        for msg in ws   # ✅ CORRECT JULIA METHOD
                            d = JSON.parse(String(msg))
                            k = d["k"]

                            price = tofloat(k["c"])
                            put!(channel, (s, price))

                            println("📡 LIVE $s $price")
                        end
                    end
                catch e
                    println("⚠️ RECONNECT ($s): $e")
                    sleep(2)
                end
            end
        end
    end

    # ─────────────────────────────────────────
    # ENGINE LOOP
    # ─────────────────────────────────────────
    while true

        if isready(channel)

            s, price = take!(channel)
            a = assets[s]

            update_asset!(a, price)

            sig, edge = signal(a)

            if sig != 0 && length(positions) < MAX_POSITIONS
                positions[s] = Position(s, sig, price, 1.0)
                println("📥 ENTRY $s $(sig == 1 ? "LONG" : "SHORT") edge=$edge")
            end

            @printf("💰 POS:%d | %s %.2f\n",
                length(positions), s, price)

        else
            print("⏳ waiting...\r")
            sleep(0.2)
        end
    end
end

run()