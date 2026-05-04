using HTTP, JSON, Dates, Statistics, Printf

# ─────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────

const SYMBOL = "BTCUSDT"
const REST_URL = "https://api.binance.com"
const FEE = 0.001

# ─────────────────────────────────────────
# POSITION STATE MACHINE
# ─────────────────────────────────────────

mutable struct Position
    side::Int64          # 1 for Long, -1 for Short
    entry::Float64
    size::Float64
    age::Int64           # Measured in seconds (ticks)

    last_pnl::Float64
    stagnant_ticks::Int64
    unrealized_pnl::Float64
    peak_pnl::Float64

    
    active::Bool
end

# ─────────────────────────────────────────
# IGGY CORE STATE
# ─────────────────────────────────────────

mutable struct IGGY
    equity::Float64
    peak::Float64

    mid_price::Float64
    prev_price::Float64

    book_pressure::Float64
    volatility::Float64

    stability::Float64

    stag_limit::Int64       # Auto-adjusts between 30 and 180
    stag_threshold::Float64 # Auto-adjusts between 1e-7 and 5e-6
    entry_threshold::Float64 # Auto-adjusts confidence (0.6 - 0.8)

   

    position::Union{Position, Nothing}
end

# ─────────────────────────────────────────
# LEARNING LOOP (Meta-Optimization)
# ─────────────────────────────────────────

function update_algorithm!(state, last_reason, last_pnl)
    # If we just exited a zombie trade (STAGNATION)
    if last_reason == :STAGNATION
        println("🧠 LEARNING: Cutting stagnation limit. Being more aggressive.")
        state.stag_limit = max(30, state.stag_limit - 10)
        state.stag_threshold = min(5e-6, state.stag_threshold * 1.2)
    
    # If we hit a STOP_LOSS, we were too aggressive/confident
    elseif last_reason == :STOP_LOSS
        println("🧠 LEARNING: Increasing entry requirements. Filtering noise.")
        state.entry_threshold = min(0.85, state.entry_threshold + 0.02)
        state.stag_limit = min(180, state.stag_limit + 5)

    # If we had a massive PROFIT (Take Profit/Time Exit with gain)
    elseif last_pnl > 0.002
        println("🧠 LEARNING: Profitable regime detected. Locking in settings.")
        state.entry_threshold = max(0.6, state.entry_threshold - 0.01)
    end
end

# ─────────────────────────────────────────
# MARKET DATA
# ─────────────────────────────────────────

function get_price()
    try
        res = HTTP.get("$REST_URL/api/v3/ticker/price?symbol=$SYMBOL", readtimeout=5)
        data = JSON.parse(String(res.body))
        return parse(Float64, data["price"])
    catch e
        println("⚠️ Connection Error: $e")
        return 0.0
    end
end

# ─────────────────────────────────────────
# PERCEPTION ENGINE (FIXED ANCHORS)
# ─────────────────────────────────────────

function update_perception!(state, price)
    if price == 0.0; return; end
    
    state.prev_price = state.mid_price
    state.mid_price = price

    # Initialize prev_price on first run to avoid infinity volatility
    prev = state.prev_price == 0 ? price : state.prev_price

    # Volatility Calculation
    state.volatility = abs(price - prev) / prev

    # FIX: Anchored Book Pressure (Prevents self-reinforcing ghost trends)
    state.book_pressure = (0.95 * state.book_pressure) +
                          (0.05 * sign(price - prev) * state.volatility)

    # Slow Leak: Naturally returns pressure to zero over time
    state.book_pressure *= 0.999

    # Stability: High when volatility is low, helps filter noise
    state.stability = exp(-state.volatility * 4000)
end

# ─────────────────────────────────────────
# DECISION ENGINE (REGIME FILTER)
# ─────────────────────────────────────────

function decide(state)
    # Don't trade if the market isn't moving
    if state.volatility < 1e-7; return 0; end

    trend = sign(state.book_pressure)
    score = trend * state.stability

    # Score threshold for entry confidence
    if abs(score) < 0.65
        return 0
    end

    return Int(sign(score))
end

# ─────────────────────────────────────────
# EXIT LOGIC (VOLATILITY ADAPTIVE)
# ─────────────────────────────────────────

# ─────────────────────────────────────────
# UPDATED EXIT LOGIC (USING LEARNED WEIGHTS)
# ─────────────────────────────────────────

function should_exit(pos, state)
    pnl = pos.unrealized_pnl
    vol_stop = max(0.0008, state.volatility * 3)

    if pnl < -vol_stop; return true, :STOP_LOSS; end

    # Use the LEARNED threshold for stagnation
    price_move = abs(state.mid_price - state.prev_price) / state.mid_price
    if price_move < state.stag_threshold
        pos.stagnant_ticks += 1
    else
        pos.stagnant_ticks = 0
    end

    # Use the LEARNED limit
    if pos.stagnant_ticks > state.stag_limit
        return true, :STAGNATION
    end

    return false, :HOLD
end

# ─────────────────────────────────────────
# POSITION UPDATE (SYMMETRIC PnL)
# ─────────────────────────────────────────

function update_position!(state)
    pos = state.position
    pos === nothing && return

    pos.age += 1
    price = state.mid_price

    # FIX: Clean Symmetric PnL Model for Longs and Shorts
    if pos.side == 1
        pos.unrealized_pnl = (price - pos.entry) / pos.entry
    else
        pos.unrealized_pnl = (pos.entry - price) / pos.entry
    end

    pos.peak_pnl = max(pos.peak_pnl, pos.unrealized_pnl)

    needs_exit, reason = should_exit(pos, state)
    if needs_exit
        close_position!(state, reason)
    end
end

# ─────────────────────────────────────────
# EXECUTION ENGINE
# ─────────────────────────────────────────

function open_position!(state, side)
    # Fixed size for now (0.001 BTC)
    state.position = Position(
        side,
        state.mid_price,
        0.001,
        0, 0.0, 0, 0.0, 0.0, true
    )

    println("📥 OPEN | $(side == 1 ? "LONG" : "SHORT") @ $(state.mid_price)")
end

# ─────────────────────────────────────────
# UPDATED EXECUTION ENGINE (WITH LEARNING)
# ─────────────────────────────────────────

function close_position!(state, reason)
    pos = state.position
    pos === nothing && return

    pnl = pos.unrealized_pnl - FEE
    state.equity += pnl
    state.peak = max(state.peak, state.equity)

    @printf("\n📤 CLOSE | %-12s | PnL: %.5f | EQ: %.4f\n",
            reason, pnl, state.equity)

    # --- THE PLUG: LEARNING LOOP ---
    # IGGY now evaluates HERSELF based on the trade result
    update_algorithm!(state, reason, pnl)
    # -------------------------------

    try
        open("iggy_trade_log.csv", "a") do io
            write(io, "$(now()),$(pos.side),$(pos.entry),$(state.mid_price),$(pnl),$(reason),$(state.equity)\n")
        end
    catch
        println("⚠️ CSV Write Failure")
    end

    state.position = nothing
end

# ─────────────────────────────────────────
# UPDATED MAIN LOOP (INITIALIZE WEIGHTS)
# ─────────────────────────────────────────

function run_iggy()
    # Initializing with "Safe" defaults that she will tune herself
    state = IGGY(
        1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 
        120,    # stag_limit: Starts at 2 mins
        1e-6,   # stag_threshold: Standard sensitivity
        0.65,   # entry_threshold: Confidence requirement
        nothing
    )

    println("🚀 IGGY v26 ACTIVE (SELF-EVOLVING)")
    println("Initial Weights: StagLimit=$(state.stag_limit)s | EntryThresh=$(state.entry_threshold)")
    
    if !isfile("iggy_trade_log.csv")
        open("iggy_trade_log.csv", "w") do io
            println(io, "Timestamp,Side,Entry,Exit,PnL,Reason,Equity")
        end
    end

    while true
        price = get_price()
        if price == 0.0; sleep(1); continue; end

        update_perception!(state, price)
        update_position!(state)

        if state.position !== nothing
            @printf("⏳ TRADE | PnL: %.5f | Age: %ds | Stag: %d/%d\r",
                    state.position.unrealized_pnl,
                    state.position.age,
                    state.position.stagnant_ticks,
                    state.stag_limit)
        else
            signal = decide(state)
            if signal != 0
                open_position!(state, signal)
            else
                @printf("📊 IDLE | EQ: %.4f | P: %.2f | STB: %.2f | PRS: %.3f\r",
                        state.equity, state.mid_price, state.stability, state.book_pressure)
            end
        end

        if state.equity < 0.7
            println("\n🛑 DRAWDOWN STOP")
            break
        end

        sleep(1)
    end
end
run_iggy()