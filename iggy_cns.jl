# ==============================================================================
# IGGY — CNS v2.8 PRODUCTION ARCHITECTURE (FINAL INTEGRATED LOOP)
# ==============================================================================

using Dates, Statistics, Printf, Random

# ─────────────────────────────────────────
# 1. GLOBAL CONFIG & RISK PARAMETERS
# ─────────────────────────────────────────
const FEE                   = 0.0004f0   # 0.04% Exchange Fee
const SLIPPAGE              = 0.0002f0   # 0.02% Estimated Slippage
const MAX_DD                = 0.10f0     # 10% Global Capital Kill-Switch
const MIN_EDGE_REQUIRED     = 0.0018f0   # Minimum expected net profit to enter
const TRANSITION_LOCK_TICKS = 30         # Wait 30 steps after regime change
const CONFIDENCE_DECAY      = 0.998f0    # Natural erosion of "Brain" trust

# ─────────────────────────────────────────
# 2. CORE STRUCTURES
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

struct Position
    side::Int8          # 1 for Long, -1 for Short
    entry::Float32
    size::Float32
    tp::Float32
    sl::Float32
    age::Int
end

# ─────────────────────────────────────────
# 3. REGIME & TRANSITION LOGIC
# ─────────────────────────────────────────
function update_regime_state!(brain::Brain, current_vol::Float32)
    # Detect regime based on volatility thresholds
    new_regime = :CHOP
    if current_vol > 0.0006f0
        new_regime = :BREAKOUT
    elseif current_vol > 0.0002f0
        new_regime = :TREND
    end

    # Handle Transition Lock (Anti-False Entry)
    if new_regime != brain.last_regime
        brain.last_regime = new_regime
        brain.transition_timer = TRANSITION_LOCK_TICKS
    end

    if brain.transition_timer > 0
        brain.transition_timer -= 1
    end

    return new_regime
end

# ─────────────────────────────────────────
# 4. DECISION ENGINE (THE PROFIT GATE)
# ─────────────────────────────────────────
function calculate_signal_and_quality(brain::Brain, strat::Strategy, regime::Symbol)
    # Neural signal (represented here as a raw float)
    raw_neural_signal = randn() * 0.8f0 
    
    # Apply Brain Confidence & Strategy Weighting
    # This prevents "Lucky Streak Delusion"
    weighted_signal = raw_neural_signal * brain.confidence * strat.weight
    
    # Regime-specific dampening
    if regime == :CHOP
        weighted_signal *= 0.3f0
    elseif regime == :TREND
        weighted_signal *= 1.1f0
    end

    # Net Edge = Signal - Costs (FEE + SLIPPAGE)
    net_edge = abs(weighted_signal) - (FEE + SLIPPAGE)
    
    return Float32(weighted_signal), Float32(net_edge)
end

# ─────────────────────────────────────────
# 5. EXECUTION & RISK ENGINE
# ─────────────────────────────────────────
function execute_trade(price, signal, net_edge, capital, brain, regime)
    # Veto check: Transition Lock, Global Halt, or insufficient edge
    if brain.transition_timer > 0 || net_edge < MIN_EDGE_REQUIRED
        return nothing
    end

    # Dynamic Position Sizing based on Regime
    # Risk 2% in Trends, 0.5% in Chop
    risk_mod = regime == :TREND ? 0.02f0 : 0.005f0
    size = capital.balance * risk_mod
    
    side = signal > 0 ? 1 : -1
    
    # Triple Barrier Setup
    tp_price = price * (1 + (side * 0.005f0)) # 0.5% Target
    sl_price = price * (1 - (side * 0.003f0)) # 0.3% Stop

    return Position(Int8(side), price, size, tp_price, sl_price, 0)
end

# ─────────────────────────────────────────
# 6. EXIT & FEEDBACK ENGINE
# ─────────────────────────────────────────
function evaluate_exit!(pos::Position, price, capital, brain, strat, regime)
    pnl_raw = (price - pos.entry) / pos.entry * pos.side
    
    # Barriers: TP, SL, or Time Exhaustion (200 ticks)
    is_tp = (pos.side == 1 && price >= pos.tp) || (pos.side == -1 && price <= pos.tp)
    is_sl = (pos.side == 1 && price <= pos.sl) || (pos.side == -1 && price >= pos.sl)
    is_expired = pos.age > 200

    if is_tp || is_sl || is_expired
        net_pnl_pct = pnl_raw - FEE - SLIPPAGE
        actual_profit = net_pnl_pct * pos.size
        
        # ── FEEDBACK LOOP
        # Update Capital
        capital.balance += actual_profit
        capital.peak = max(capital.peak, capital.balance)
        capital.dd = (capital.peak - capital.balance) / capital.peak
        
        # Update Brain (Learning from reality)
        # Penalize losses harder than rewarding wins (Survival bias)
        brain.confidence = clamp(brain.confidence * CONFIDENCE_DECAY + (net_pnl_pct > 0 ? 0.02f0 : -0.05f0), 0.1f0, 1.0f0)
        brain.regime_memory[regime] = get(brain.regime_memory, regime, 0f0) + net_pnl_pct
        
        # Update Strategy Weighting
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
    # Initialization
    capital = Capital(1000.0f0, 1000.0f0, 0.0f0)
    brain   = Brain(0.8f0, Dict{Symbol, Float32}(), :TREND, 0)
    strat   = Strategy(1.0f0, Float32[], 0.0f0)
    
    pos     = nothing
    tick    = 0

    println("--------------------------------------------------")
    println("🔥 IGGY CNS v2.8 FULL CLOSED-LOOP SYSTEM ACTIVE")
    println("--------------------------------------------------")

    while capital.dd < MAX_DD
        tick += 1
        
        # 1. Market Data Ingestion
        # 1. Market Data Ingestion
# We use f0 or Float32() to ensure we don't pass a Float64 to our CNS functions
sim_price = 80000.0f0 + Float32(randn()) * 15.0f0
sim_vol   = abs(Float32(randn())) * 0.0004f0
        
        # 2. Update Environment & Transition Logic
        regime = update_regime_state!(brain, sim_vol)
        
        # 3. Handle Active Positions (Exit Logic First)
        if pos !== nothing
            exit_profit = evaluate_exit!(pos, sim_price, capital, brain, strat, regime)
            if exit_profit != 0.0f0
                pos = nothing # Position cleared
            else
                # Update position age if still active
                pos = Position(pos.side, pos.entry, pos.size, pos.tp, pos.sl, pos.age + 1)
            end
        end

        # 4. Signal Generation & Entry (Only if idle)
        if pos === nothing
            sig, edge = calculate_signal_and_quality(brain, strat, regime)
            pos = execute_trade(sim_price, sig, edge, capital, brain, regime)
        end

        # 5. Telemetry (Every 10 ticks to avoid screen spam)
        if tick % 10 == 0
            @printf("💰 BAL: \$%.2f | DD: %.2f%% | CONF: %.2f | REGIME: %s | LOCK: %d\r", 
                    capital.balance, capital.dd * 100, brain.confidence, string(regime), brain.transition_timer)
        end

        sleep(0.1)
    end

    println("\n🛑 GLOBAL KILL-SWITCH: Drawdown limit reached or system halted.")
    println("Final Balance: \$", round(capital.balance, digits=2))
end

# Execute the system
run_iggy_system()