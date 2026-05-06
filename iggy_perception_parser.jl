module IggyPerception

# ── NOTE ──────────────────────────────────────────────────────────────────────
# using ..IggyOntology does NOT work here — IggyOntology is in Main, not a
# parent module.  Use import Main.IggyOntology instead.
# ─────────────────────────────────────────────────────────────────────────────
import Main.IggyOntology

# ─────────────────────────────────────────
# INTENT RECOGNITION
# ─────────────────────────────────────────

"""
    parse_user_input(input_text, kg) -> (intent::Symbol, entities::Dict)

Keyword-based intent classifier.  Returns a Symbol intent and any extracted
entities.  Falls back to :unknown so iggy_bridge can route to the LLM brain.
"""
function parse_user_input(input_text::String, kg::IggyOntology.KnowledgeGraph)
    t = lowercase(strip(input_text))
    intent   = :unknown
    entities = Dict{Symbol, Any}()

    # ── Greetings ─────────────────────────────────────────────────
    if occursin(r"^(hi|hey|hello|sup|yo|greetings|good morning|good evening|morning|evening)(\s|$|,|!)", t) ||
       occursin("hi iggy", t) || occursin("hey iggy", t) || occursin("hello iggy", t)
        intent = :general_greeting

    # ── Wellbeing ──────────────────────────────────────────────────
    elseif occursin("how are you", t) || occursin("you doing", t) || occursin("you ok", t)
        intent = :query_wellbeing

    # ── Identity ───────────────────────────────────────────────────
    elseif occursin("who are you", t) || occursin("what are you", t) || occursin("your name", t)
        intent = :query_identity

    # ── Capabilities ───────────────────────────────────────────────
    elseif occursin("what can you do", t) || occursin("your capabilities", t) || occursin("help me", t)
        intent = :query_capabilities
    end

    # ── CNS / trading status (checked separately so it can override) ─
    if occursin("status", t) || occursin("trading status", t) ||
       occursin("how are we doing", t) || occursin("current balance", t) ||
       occursin("balance", t) || occursin("capital", t) ||
       occursin("pnl", t) || occursin("profit", t) || occursin("drawdown", t)
        intent = :query_cns_status

    elseif occursin("trade history", t) || occursin("past trades", t) || occursin("history", t)
        intent = :query_cns_trade_history

    elseif occursin("open positions", t) || occursin("active trades", t) ||
           occursin("positions", t)
        intent = :query_cns_open_positions
    end

    # ── Knowledge queries ──────────────────────────────────────────
    m = match(r"tell me about (.+)", t)
    if m !== nothing
        intent = :query_knowledge
        entities[:topic] = strip(m.captures[1])
    end

    m = match(r"what is (.+)", t)
    if m !== nothing && intent == :unknown
        intent = :query_knowledge
        entities[:topic] = strip(m.captures[1])
    end

    m = match(r"learn about (.+)", t)
    if m !== nothing
        intent = :learn_fact
        entities[:topic] = strip(m.captures[1])
    end

    # ── Entity: user name ──────────────────────────────────────────
    m = match(r"my name is (\w+)", t)
    if m !== nothing
        entities[:user_name] = m.captures[1]
    end

    return intent, entities
end

# ─────────────────────────────────────────
# FACT ENCODER  (placeholder)
# ─────────────────────────────────────────
function parse_input_to_fact!(kg::IggyOntology.KnowledgeGraph, input_data::Dict)
    subject   = get(input_data, :subject,   :Unknown)
    predicate = get(input_data, :predicate, IggyOntology.PRED_CONNECTED_TO)
    object    = get(input_data, :object,    :Unknown)
    println("Perception: Encoded ($subject, $predicate, $object)")
    IggyOntology.add_fact!(kg, subject, predicate, object)
end

end  # module IggyPerception
