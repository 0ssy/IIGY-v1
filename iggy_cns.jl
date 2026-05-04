using HTTP, JSON, Dates, Statistics, Printf

# ─────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────
const SYMBOLS = ["BTCUSDT", "ETHUSDT", "SOLUSDT"]
const BASE_URL = "https://testnet.binance.vision"

const FEE = 0.0004
const SLIPPAGE = 0.0002
const EXTRA_COST = 0.0003
const MAX_DD = 0.10
const MAX_POSITIONS = 2

# Strategy Parameters
const MACD_FAST_PERIOD = 12
const MACD_SLOW_PERIOD = 26
const MACD_SIGNAL_PERIOD = 9
const ATR_PERIOD = 14
const ATR_MULTIPLIER_SL = 2.0 # Multiplier for ATR to set stop loss
const ATR_MULTIPLIER_TP = 4.0 # Multiplier for ATR to set take profit
const RISK_PER_TRADE_PERCENT = 0.01 # 1% of capital per trade

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
    high::Float64 # Added for ATR
    low::Float64  # Added for ATR
    close_history::Vector{Float64} # Added for indicators
    vol::Float64
    pressure::Float64
    stability::Float64
    trend::Float64
    cooldown::Int
    vol_cluster::Float64
    
    # MACD indicators
    macd_fast_ema::Float64
    macd_slow_ema::Float64
    macd_signal_ema::Float64
    macd_line::Float64
    signal_line::Float64

    # ATR
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
# HELPER FUNCTIONS FOR INDICATORS
# ─────────────────────────────────────────
function calculate_ema(prices::Vector{Float64}, period::Int, prev_ema::Float64)
    if isempty(prices) || period <= 0
        return 0.0
    end
    alpha = 2 / (period + 1)
    if prev_ema == 0.0
        return sum(prices) / length(prices) # Simple average for initial EMA
    else
        return alpha * prices[end] + (1 - alpha) * prev_ema
    end
end

function calculate_atr(asset::Asset, period::Int)
    if length(asset.close_history) < period
        return 0.0
    end

    true_ranges = Float64[]
    for i in max(1, length(asset.close_history) - period + 1):length(asset.close_history)
        current_high = asset.high # This needs to be the high of the current candle
        current_low = asset.low   # This needs to be the low of the current candle
        prev_close = (i > 1) ? asset.close_history[i-1] : asset.prev # Use previous close from history

        tr1 = current_high - current_low
        tr2 = abs(current_high - prev_close)
        tr3 = abs(current_low - prev_close)
        push!(true_ranges, max(tr1, tr2, tr3))
    end
    return sum(true_ranges) / length(true_ranges)
end

# ─────────────────────────────────────────
# DATA
# ─────────────────────────────────────────
function get_price(sym)
    try
        res = HTTP.get("$BASE_URL/api/v3/ticker/price?symbol=$sym")
        data = JSON.parse(String(res.body))
        return parse(Float64, data["price"])
    catch e
        println("Error fetching price for $sym: $e")
        return nothing
    end
end

# ─────────────────────────────────────────
# PERCEPTION
# ─────────────────────────────────────────
function update_asset!(a, price, high=price, low=price) # Added high and low for ATR
    if price === nothing; return; end

    a.prev = a.price == 0 ? price : a.price
    a.price = price
    a.high = high # Update high
    a.low = low   # Update low

    push!(a.close_history, price)
    if length(a.close_history) > max(MACD_SLOW_PERIOD, ATR_PERIOD)
        popfirst!(a.close_history)
    end

    a.vol = abs(price - a.prev) / a.prev

    a.pressure = 0.9a.pressure + 0.1 * sign(price - a.prev) * a.vol
    a.pressure *= 0.995

    a.stability = exp(-a.vol * 3000)
    a.trend = 0.9a.trend + 0.1 * sign(price - a.prev)

    # volatility clustering
    a.vol_cluster = 0.95a.vol_cluster + 0.05 * a.vol

    # Update MACD
    if length(a.close_history) >= MACD_SLOW_PERIOD
        a.macd_fast_ema = calculate_ema(a.close_history, MACD_FAST_PERIOD, a.macd_fast_ema)
        a.macd_slow_ema = calculate_ema(a.close_history, MACD_SLOW_PERIOD, a.macd_slow_ema)
        a.macd_line = a.macd_fast_ema - a.macd_slow_ema
        a.macd_signal_ema = calculate_ema([a.macd_line], MACD_SIGNAL_PERIOD, a.macd_signal_ema)
        a.signal_line = a.macd_signal_ema
    end

    # Update ATR
    a.atr = calculate_atr(a, ATR_PERIOD)
end

# ─────────────────────────────────────────
# ML REGIME (LIGHTWEIGHT)
# ─────────────────────────────────────────
function classify_regime(a)
    score = a.vol * 10000 + abs(a.pressure) * 5000 + abs(a.trend)

    if score < 1
        return :DEAD
    elseif score < 3
        return :CHOP
    else
        return :TREND
    end
end

# ─────────────────────────────────────────
# SIGNAL
# ─────────────────────────────────────────
function generate_signal(a, brain, strat, regime)
    if brain.transition_timer > 0 || regime != :TREND || a.cooldown > 0
        return 0, 0.0
    end

    momentum = sign(a.price - a.prev)
    pressure = sign(a.pressure)

    # MACD signal: Crossover of MACD line and Signal line
    macd_signal = 0
    if a.macd_line > a.signal_line && a.macd_line - a.vol_cluster > a.signal_line # MACD crosses above signal line with some buffer
        macd_signal = 1
    elseif a.macd_line < a.signal_line && a.macd_line + a.vol_cluster < a.signal_line # MACD crosses below signal line with some buffer
        macd_signal = -1
    end

    # Confluence: momentum, pressure, trend, and MACD must align
    if momentum != pressure || sign(a.trend) != pressure || macd_signal != momentum
        return 0, 0.0
    end

    if a.stability < 0.3 || abs(a.pressure) < 0.0004 || a.atr == 0.0
        return 0, 0.0
    end

    score = pressure * a.stability * brain.confidence * strat.weight
    edge = abs(score) - (FEE + SLIPPAGE + EXTRA_COST)

    return edge > 0 ? (Int(pressure), edge) : (0, edge)
end

# ─────────────────────────────────────────
# RISK
# ─────────────────────────────────────────
function position_size(capital, a)
    # Dynamic risk based on ATR and a fixed percentage of capital
    if a.atr == 0.0
        return 0.0
    end
    
    risk_amount = capital.balance * RISK_PER_TRADE_PERCENT
    stop_loss_in_price = a.atr * ATR_MULTIPLIER_SL
    
    # Calculate size based on how much capital to risk per trade and the stop loss distance
    size = risk_amount / stop_loss_in_price
    
    # Clamp size to reasonable values (adjust as needed)
    return clamp(size, 0.0001, 0.05) # Increased max size for potential higher volatility
end

function open_position(a, signal, capital)
    size = position_size(capital, a)
    if size == 0.0; return nothing; end

    # Dynamic TP/SL from ATR
    tp_dist = a.atr * ATR_MULTIPLIER_TP
    sl_dist = a.atr * ATR_MULTIPLIER_SL

    tp = a.price * (1 + signal * tp_dist)
    sl = a.price * (1 - signal * sl_dist)

    return Position(a.symbol, signal, a.price, size, tp, sl, 0.0, 0)
end

# ─────────────────────────────────────────
# EXIT + LEARNING
# ─────────────────────────────────────────
function close_trade!(pos, pnl, capital, brain, strat, reason, assets)
    net = (pnl - FEE - SLIPPAGE) * pos.size

    capital.balance += net
    capital.peak = max(capital.peak, capital.balance)
    capital.dd = (capital.peak - capital.balance) / capital.peak

    # cooldown after loss (dynamic based on ATR or vol_cluster)
    if net < 0
        assets[pos.symbol].cooldown = round(Int, 15 * (1 + assets[pos.symbol].vol_cluster / 0.005)) # Longer cooldown for higher volatility
    end

    # brain learning
    brain.confidence = clamp(brain.confidence + (net > 0 ? 0.01 : -0.03), 0.1, 1.0)

    push!(strat.pnl_history, net)
    strat.expectancy = mean(strat.pnl_history[max(1,end-30):end])
    strat.weight = clamp(1 + strat.expectancy * 5, 0.5, 2.0)

    # journaling (structured)
    open("iggy_journal.csv","a") do io
        write(io, "$(now()),$(pos.symbol),$(pos.side),$(pos.entry),$(net),$(reason),$(capital.balance)\n")
    end

    println("\n📤 $(pos.symbol) | $reason | PnL: $(round(net, digits=5)) | EQ: $(round(capital.balance, digits=2))")

    return true
end

function update_position!(pos, a, capital, brain, strat, assets)
    pos.age += 1
    pnl = (a.price - pos.entry) / pos.entry * pos.side
    pos.peak = max(pos.peak, pnl)

    # ATR-based Stop Loss
    if a.atr > 0.0 && pnl < - (a.atr * ATR_MULTIPLIER_SL / pos.entry)
        return close_trade!(pos, pnl, capital, brain, strat, :SL_ATR, assets)
    end

    # Trailing Stop (original logic, still useful)
    if pos.peak > 0.003 && pnl < pos.peak * 0.65
        return close_trade!(pos, pnl, capital, brain, strat, :TRAIL, assets)
    end

    # Take Profit
    if (pos.side == 1 && a.price >= pos.tp) || (pos.side == -1 && a.price <= pos.tp)
        return close_trade!(pos, pnl, capital, brain, strat, :TP, assets)
    end

    return false
end

# ─────────────────────────────────────────
# MAIN LOOP
# ─────────────────────────────────────────
function run_iggy()
    capital = Capital(1000.0,1000.0,0.0)
    strat = Strategy(1.0,Float64[],0.0)

    assets = Dict{String,Asset}()
    brains = Dict{String,Brain}()

    for s in SYMBOLS
        # Initialize Asset with new fields
        assets[s] = Asset(s,0.0,0.0,0.0,0.0,Float64[],0.0,0.0,0.0,0.0,0,0.0,0.0,0.0,0.0,0.0,0.0,0.0)
        brains[s] = Brain(0.8,:TREND,0)
    end

    positions = Dict{String,Position}()

    println("🚀 IGGY CNS v4 ACTIVE - IMPROVED")

    while capital.dd < MAX_DD
        for (sym,a) in assets
            # In a real scenario, this would be a WebSocket stream providing OHLCV data
            # For this simulation, we'll fetch price and assume high/low are current price for simplicity
            # A more robust solution would fetch actual OHLCV data for ATR calculation
            price = get_price(sym)
            if price !== nothing
                # For simplicity in this single-file context, we'll use current price for high/low
                # In a real bot, you'd get actual candle data (OHLCV) for accurate ATR.
                update_asset!(a, price, price, price)
            else
                println("Warning: Could not get price for $sym. Skipping update.")
            end
        end

        # update positions
        for (sym,pos) in copy(positions)
            if update_position!(pos, assets[sym], capital, brains[sym], strat, assets)
                delete!(positions, sym)
            end
        end

        # entries
        if length(positions) < MAX_POSITIONS
            for (sym,a) in assets
                if haskey(positions, sym) || a.cooldown > 0
                    continue
                end

                regime = classify_regime(a)
                brain = brains[sym]

                signal, edge = generate_signal(a, brain, strat, regime)
                if signal != 0
                    new_pos = open_position(a, signal, capital)
                    if new_pos !== nothing
                        positions[sym] = new_pos
                        println("📥 OPEN | $sym | $(signal==1 ? "LONG" : "SHORT") | Edge=$(round(edge, digits=5)) | Size=$(round(new_pos.size, digits=5))")
                    else
                        println("🚫 Could not open position for $sym. Size calculation failed.")
                    end
                end
            end
        end

        @printf("💰 %.2f | DD: %.2f%% | Active: %d\r",
            capital.balance, capital.dd*100, length(positions))

        sleep(1) # Simulate real-time updates, but a real bot would be event-driven via WebSockets
    end

    println("\n🛑 STOPPED (MAX DD)")
end

run_iggy()

