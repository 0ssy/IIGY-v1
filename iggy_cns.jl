# ==============================================================================
# IGGY — CNS v2.9 INTEGRATED PRODUCTION ARCHITECTURE
# Merged: Logic v2.8 + Live Binance Connectivity
# ==============================================================================

using HTTP, JSON, SHA, Dates, Statistics, Printf, Random

# ─────────────────────────────────────────
# 1. GLOBAL CONFIG & RISK PARAMETERS
# ─────────────────────────────────────────
const BASE_URL              = "https://testnet.binance.vision"
const FEE                   = 0.0004f0   # 0.04% Exchange Fee
const SLIPPAGE              = 0.0002f0   # 0.02% Estimated Slippage
const MAX_DD                = 0.10f0     # 10% Global Capital Kill-Switch
const MIN_EDGE_REQUIRED     = 0.0018f0   # Minimum expected net profit to enter
const TRANSITION_LOCK_TICKS = 30         # Wait 30 steps after regime change
const CONFIDENCE_DECAY      = 0.998f0    # Natural erosion of "Brain" trust

# ─────────────────────────────────────────
# 2. CORE STRUCTURES (v2.8)
# ─────────────────────────────────────────
mutable struct Capital
    balance::Float32
    peak::Float32
    dd::Float32
end

mutable struct Brain
    confidence::Float32
    regime_memory::Dict{Symbol, Float32}
    last_regime::Symbol
    transition_timer::Int
end

mutable struct Strategy
    weight::Float32
    pnl_history::Vector{Float32}
    avg_expectancy::Float32
end

mutable struct Position
    side::Int8          # 1 for Long, -1 for Short
    entry::Float32
    size::Float32
    tp::Float32
    sl::Float32
    age::Int
end

# ─────────────────────────────────────────
# 3. CONNECTIVITY HELPERS
# ─────────────────────────────────────────
function hmac_sha256_hex(key, msg)
    return bytes2hex(hmac_sha256(Vector{UInt8}(key), Vector{UInt8}(msg)))
end

function get_live_price(symbol="BTCUSDT")
    url = "$BASE_URL/api/v3/ticker/price?symbol=$symbol"
    try
        res = HTTP.get(url)
        return parse(Float32, JSON.parse(String(res.body))["price"])
    catch
        return nothing
    end
end

# ─────────────────────────────────────────
# 4. REGIME & DECISION LOGIC (v2.8)
# ─────────────────────────────────────────
function update_regime_state!(brain::Brain, current_vol::Float32)
    new_regime = :CHOP
    if current_vol > 0.0006f0
        new_regime = :BREAKOUT
    elseif current_vol > 0.0002f0
        new_regime = :TREND
    end

    if new_regime != brain.last_regime
        brain.last_regime = new_regime
        brain.transition_timer = TRANSITION_LOCK_TICKS
    end

    if brain.transition_timer > 0
        brain.transition_timer -= 1
    end
    return new_regime
end

function calculate_signal_and_quality(brain::Brain, strat::Strategy, regime::Symbol)
    raw_neural_signal = randn() * 0.8f0 
    weighted_signal = raw_neural_signal * brain.confidence * strat.weight
    
    if regime == :CHOP
        weighted_signal *= 0.3f0
    elseif regime == :TREND
        weighted_signal *= 1.1f0
    end

    net_edge = abs(weighted_signal) - (FEE + SLIPPAGE)
    return Float32(weighted_signal), Float32(net_edge)
end

# ─────────────────────────────────────────
# 5. EXECUTION ENGINE
# ─────────────────────────────────────────
function execute_trade(api_key, api_secret, price, signal, net_edge, capital, brain, regime)
    if brain.transition_timer > 0 || net_edge < MIN_EDGE_REQUIRED
        return nothing
    end

    risk_mod = regime == :TREND ? 0.02f0 : 0.005f0
    size = capital.balance * risk_mod
    side_str = signal > 0 ? "BUY" : "SELL"
    side_int = signal > 0 ? 1 : -1
    
    # Validating signal via Binance /order/test endpoint
    endpoint = "/api/v3/order/test"
    ts = Int64(floor(datetime2unix(now(Dates.UTC)) * 1000))
    query = "symbol=BTCUSDT&side=$side_str&type=MARKET&quantity=0.001&timestamp=$ts&recvWindow=5000"
    sig = hmac_sha256_hex(api_secret, query)
    
    try
        HTTP.post("$BASE_URL$endpoint?$query&signature=$sig", ["X-MBX-APIKEY" => api_key])
        
        # Triple Barrier Initialization
        tp_price = price * (1 + (side_int * 0.005f0))
        sl_price = price * (1 - (side_int * 0.003f0))
        
        return Position(Int8(side_int), price, size, tp_price, sl_price, 0)
    catch e
        return nothing
    end
end

# ─────────────────────────────────────────
# 6. FEEDBACK ENGINE (v2.8)
# ─────────────────────────────────────────
function evaluate_exit!(pos::Position, price, capital, brain, strat, regime)
    pnl_raw = (price - pos.entry) / pos.entry * pos.side
    
    is_tp = (pos.side == 1 && price >= pos.tp) || (pos.side == -1 && price <= pos.tp)
    is_sl = (pos.side == 1 && price <= pos.sl) || (pos.side == -1 && price >= pos.sl)
    is_expired = pos.age > 200

    if is_tp || is_sl || is_expired
        net_pnl_pct = pnl_raw - FEE - SLIPPAGE
        actual_profit = net_pnl_pct * pos.size
        
        capital.balance += actual_profit
        capital.peak = max(capital.peak, capital.balance)
        capital.dd = (capital.peak - capital.balance) / capital.peak
        
        brain.confidence = clamp(brain.confidence * CONFIDENCE_DECAY + (net_pnl_pct > 0 ? 0.02f0 : -0.05f0), 0.1f0, 1.0f0)
        push!(strat.pnl_history, net_pnl_pct)
        strat.avg_expectancy = mean(strat.pnl_history[max(1, end-20):end])
        strat.weight = clamp(1.0f0 + (strat.avg_expectancy * 10f0), 0.5f0, 2.0f0)

        return actual_profit
    end
    return 0.0f0
end

# ─────────────────────────────────────────
# 7. MAIN CONTROL LOOP
# ─────────────────────────────────────────
function run_iggy_system()
    api_key = get(ENV, "BINANCE_API_KEY", "")
    api_secret = get(ENV, "BINANCE_API_SECRET", "")
    
    if api_key == "" || api_secret == ""
        println("❌ ERROR: Environment Keys missing.")
        return
    end

    capital = Capital(1000.0f0, 1000.0f0, 0.0f0)
    brain   = Brain(0.8f0, Dict{Symbol, Float32}(), :TREND, 0)
    strat   = Strategy(1.0f0, Float32[], 0.0f0)
    pos     = nothing
    tick    = 0

    println("--------------------------------------------------")
    println("📡 IGGY CNS v2.9: LIVE MARKET FEED + TESTNET API")
    println("--------------------------------------------------")

    while capital.dd < MAX_DD
        tick += 1
        live_price = get_live_price()
        
        if live_price === nothing
            sleep(2); continue
        end

        # Market Volatility Simulation for Regime Awareness
        vol = abs(Float32(randn())) * 0.0004f0
        regime = update_regime_state!(brain, vol)
        
        if pos !== nothing
            pos.age += 1
            if evaluate_exit!(pos, live_price, capital, brain, strat, regime) != 0.0f0
                pos = nothing
            end
        elseif pos === nothing
            sig, edge = calculate_signal_and_quality(brain, strat, regime)
            pos = execute_trade(api_key, api_secret, live_price, sig, edge, capital, brain, regime)
        end

        if tick % 5 == 0
            @printf("💰 \$%.2f | DD: %.2f%% | BTC: \$%.2f | REGIME: %s\r", 
                    capital.balance, capital.dd * 100, live_price, string(regime))
        end
        sleep(1.0)
    end
    println("\n🛑 SYSTEM HALTED: Drawdown limit reached.")
end

run_iggy_system()