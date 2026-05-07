using Dates, JSON, Printf

# ── NOTE ──────────────────────────────────────────────────────────────────────
# Do NOT re-include any files here. iggy_executive.jl is the single entry point
# and has already loaded all dependencies before this file is included.
# Duplicate includes cause struct / module redefinition errors that prevent
# iggy_interact from ever being defined in Main.
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────
# FEEDBACK MODULE  (placeholder)
# Must be defined BEFORE IGGYState references it.
# ─────────────────────────────────────────
mutable struct FeedbackModule
    FeedbackModule() = new()
end

# ─────────────────────────────────────────
# STATE CONTAINER
# ─────────────────────────────────────────
mutable struct IGGYState
    kg            :: IggyOntology.KnowledgeGraph
    fm            :: FeedbackModule
    cns_capital   :: Capital
    cns_strategy  :: Strategy
    cns_assets    :: Dict{String, Asset}
    cns_brains    :: Dict{String, Brain}
    cns_positions :: Dict{String, Position}
    user_context  :: Dict{Symbol, Any}
    last_response :: String
end

# ─────────────────────────────────────────
# INITIALISE
# ─────────────────────────────────────────
function initialize_iggy_state()
    kg = IggyOntology.KnowledgeGraph()

    # Seed core ontology.
    # TYPE_AI_SYSTEM does not exist in iggy_ontology.jl — TYPE_DOMAIN is the
    # closest available type.  add_relationship! also doesn't exist; use add_fact!.
    IggyOntology.add_entity!(kg, :IGGY, IggyOntology.TYPE_DOMAIN)
    IggyOntology.add_entity!(kg, :User, IggyOntology.TYPE_USER)
    IggyOntology.add_fact!(kg, :IGGY, IggyOntology.PRED_IS_ASSISTANT_OF, :User)
    IggyOntology.add_fact!(kg, :IGGY, IggyOntology.PRED_HAS_CREATOR, :User)

    fm = FeedbackModule()

    # CNS components
   cns_capital   = Capital(1000.0, 0.0, 1000.0, 0.0, 1000.0)
    cns_strategy  = Strategy("Adaptive-Merged", 0.02, 0.1, 2.0, 1.0, :sideways)
    cns_assets    = Dict{String,Asset}()
    cns_brains    = Dict{String,Brain}()
    cns_positions = Dict{String,Position}()

    println("📥 Initialising CNS History…")
    for s in SYMBOLS
        o, h, l, c, v = get_klines_history(s, KLINE_INTERVAL, KLINE_LIMIT)
        if c !== nothing
            cns_assets[s] = Asset(s, c[end], c[end], h[end], l[end],
                                  o[end], v[end], c, h, l,
                                  0.0, 0.0, 0.0, 0.0, 0, 0.0,
                                  0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
            for i in 1:length(c)
                update_asset!(cns_assets[s], o[i], h[i], l[i], c[i], v[i])
            end
        else
            println("⚠️  Could not fetch initial klines for $s.")
        end
        cns_brains[s] = Brain(1.0, :TREND, 0)
    end

    user_context = Dict{Symbol,Any}(
        :name        => "Joseph",
        :preferences => Dict{Symbol,Any}()
    )

    return IGGYState(kg, fm, cns_capital, cns_strategy,
                     cns_assets, cns_brains, cns_positions,
                     user_context, "")
end

# ─────────────────────────────────────────
# CORE INTERACTION — Perceive · Reason · Act
# ─────────────────────────────────────────
function iggy_interact(iggy::IGGYState, user_input::String) :: String

    # ── 1. PERCEIVE ───────────────────────────────────────────────
    parsed_intent, entities = IggyPerception.parse_user_input(user_input, iggy.kg)
    println("  [intent=$parsed_intent  entities=$entities]")

    if haskey(entities, :user_name)
        iggy.user_context[:name] = entities[:user_name]
        IggyOntology.add_fact!(iggy.kg, :User,
                               IggyOntology.PRED_HAS_NAME,
                               Symbol(entities[:user_name]))
    end

    # ── 2. REASON ─────────────────────────────────────────────────
    response_text = ""

    if parsed_intent == :query_cns_status
        bal  = iggy.cns_capital.balance
        dd   = iggy.cns_capital.dd * 100
        npos = length(iggy.cns_positions)
        response_text = @sprintf(
            "Current capital: %.2f | Drawdown: %.2f%% | Open positions: %d",
            bal, dd, npos)

    elseif parsed_intent == :query_cns_trade_history
        response_text = "Trade history review is still being built."

    elseif parsed_intent == :query_cns_open_positions
        if isempty(iggy.cns_positions)
            response_text = "No open positions right now."
        else
            details = join([
                "$(p.symbol) $(p.side == 1 ? "LONG" : "SHORT") @ $(round(p.entry, digits=2))"
                for (_, p) in iggy.cns_positions], ", ")
            response_text = "Open positions: $details"
        end

    elseif parsed_intent == :general_greeting
        response_text = "Hello, $(iggy.user_context[:name]). How can I assist you today?"

    elseif parsed_intent == :query_wellbeing
        response_text = "All systems nominal — thank you for asking."

    elseif parsed_intent == :query_identity
        response_text = "I am IGGY, your personal AI assistant running on Aether OS."

    elseif parsed_intent == :query_capabilities
        response_text = "I manage your trading, learn from the world, and assist with various tasks."

    elseif parsed_intent == :learn_fact
        if haskey(entities, :topic)
            response_text = "I will learn more about $(entities[:topic])."
        else
            response_text = "What topic would you like me to learn about?"
        end

    elseif parsed_intent == :query_knowledge
        if haskey(entities, :topic)
            facts = IggyOntology.query_facts(iggy.kg, Symbol(entities[:topic]), nothing, nothing)
            if isempty(facts)
                response_text = "I don't have data on $(entities[:topic]) yet — I can try to learn it."
            else
                lines = ["- $s $p $o" for (s, p, o) in facts]
                response_text = "Here's what I know about $(entities[:topic]):\n" * join(lines, "\n")
            end
        else
            response_text = "What knowledge are you seeking?"
        end

    else
        # ── Unknown intent → ask Python LLM brain ─────────────────
        ctx = @sprintf("Capital: %.2f | DD: %.2f%% | Positions: %d",
                       iggy.cns_capital.balance,
                       iggy.cns_capital.dd * 100,
                       length(iggy.cns_positions))
        response_text = IggyPythonBridge.ask_brain(user_input, context=ctx)
    end

    # ── 3. ACT ────────────────────────────────────────────────────
    iggy.last_response = response_text
    return response_text
end
