using Dates, JSON, Printf

# Include core IGGY modules (assuming they are in the same directory or accessible)
include("iggy_ontology.jl")
include("iggy_inference_engine.jl")
include("iggy_perception_parser.jl")
include("iggy_cns_core.jl") # The trading core
include("iggy_persistence.jl") # For saving/loading state

# ─────────────────────────────────────────
# IGGY BRIDGE CORE
# ─────────────────────────────────────────
mutable struct IGGYState
    kg::IggyOntology.KnowledgeGraph
    fm::FeedbackModule # Assuming FeedbackModule is defined elsewhere or will be
    cns_capital::Capital
    cns_strategy::Strategy
    cns_assets::Dict{String, Asset}
    cns_brains::Dict{String, Brain}
    cns_positions::Dict{String, Position}
    user_context::Dict{Symbol, Any}
    last_response::String
end

function initialize_iggy_state()
    # Initialize Knowledge Graph
    kg = IggyOntology.KnowledgeGraph()
    # Add some initial core ontology
    IggyOntology.add_entity!(kg, :IGGY, IggyOntology.TYPE_AI_SYSTEM)
    IggyOntology.add_entity!(kg, :User, IggyOntology.TYPE_USER)
    IggyOntology.add_relationship!(kg, :IGGY, IggyOntology.PRED_IS_ASSISTANT_OF, :User)
    IggyOntology.add_fact!(kg, :IGGY, IggyOntology.PRED_HAS_CREATOR, :User) # Assuming user is the creator

    # Initialize Feedback Module (Placeholder for now)
    fm = FeedbackModule() # You'll need to define this struct and its initialization

    # Initialize CNS components (from iggy_cns_core.jl)
    cns_capital = Capital(1000.0, 1000.0, 0.0)
    cns_strategy = Strategy(1.0, Float64[], 0.0)
    cns_assets = Dict{String,Asset}()
    cns_brains = Dict{String,Brain}()
    cns_positions = Dict{String,Position}()

    # Load initial CNS history (this part needs to be adapted from iggy_cns_core.jl)
    println("📥 Initializing CNS History...")
    for s in SYMBOLS
        o, h, l, c, v = get_klines_history(s, KLINE_INTERVAL, KLINE_LIMIT)
        if c !== nothing
            cns_assets[s] = Asset(s, c[end], c[end], h[end], l[end], o[end], v[end], c, h, l, 0.0, 0.0, 0.0, 0.0, 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
            for i in 1:length(c)
                update_asset!(cns_assets[s], o[i], h[i], l[i], c[i], v[i])
            end
        else
            println("Error: Could not get initial kline history for $s.")
        end
        cns_brains[s] = Brain(1.0, :TREND, 0)
    end

    # User context
    user_context = Dict{Symbol, Any}(
        :name => "Joseph", # Placeholder, IGGY should learn this
        :preferences => Dict{Symbol, Any}()
    )

    return IGGYState(kg, fm, cns_capital, cns_strategy, cns_assets, cns_brains, cns_positions, user_context, "")
end

# ─────────────────────────────────────────
# CORE INTERACTION LOOP (PRA - Perceive, Reason, Act)
# ─────────────────────────────────────────
function iggy_interact(iggy::IGGYState, user_input::String)
    # 1. PERCEIVE
    # Parse user input into structured intent and entities
    parsed_intent, entities = IggyPerception.parse_user_input(user_input, iggy.kg)
    println("Perceived Intent: $parsed_intent, Entities: $entities")

    # Update user context based on input
    if haskey(entities, :user_name)
        iggy.user_context[:name] = entities[:user_name]
        IggyOntology.add_fact!(iggy.kg, :User, IggyOntology.PRED_HAS_NAME, Symbol(entities[:user_name]))
    end

    # 2. REASON
    response_text = "I'm not sure how to respond to that yet."
    action_to_take = :none

    if parsed_intent == :query_cns_status
        # Query CNS for current status
        balance = iggy.cns_capital.balance
        dd = iggy.cns_capital.dd * 100
        active_positions = length(iggy.cns_positions)
        response_text = @sprintf("Our current capital is %.2f, with a drawdown of %.2f%%. We have %d active positions.", balance, dd, active_positions)
        action_to_take = :report_cns_status
    elseif parsed_intent == :query_cns_trade_history
        # This would involve reading iggy_journal.csv or a more structured trade log
        response_text = "I can look up our trade history, but that feature is still under development."
        action_to_take = :report_cns_history
    elseif parsed_intent == :query_cns_open_positions
        if isempty(iggy.cns_positions)
            response_text = "We currently have no open positions."
        else
            pos_details = join(["$(p.symbol) $(p.side == 1 ? "LONG" : "SHORT") @ $(round(p.entry, digits=2))" for (s,p) in iggy.cns_positions], ", ")
            response_text = "We have the following open positions: $pos_details."
        end
        action_to_take = :report_cns_open_positions
    elseif parsed_intent == :general_greeting
        response_text = "Hello, $(iggy.user_context[:name]). How can I assist you today?"
        action_to_take = :greet_user
    elseif parsed_intent == :query_wellbeing
        response_text = "I am functioning optimally, thank you for asking!"
        action_to_take = :report_wellbeing
    elseif parsed_intent == :query_identity
        response_text = "I am IGGY, your personal AI assistant, running on Aether OS."
        action_to_take = :report_identity
    elseif parsed_intent == :query_capabilities
        response_text = "I can manage your trading, learn from the world, and assist you with various tasks. What would you like to explore?"
        action_to_take = :report_capabilities
    elseif parsed_intent == :learn_fact
        if haskey(entities, :topic)
            response_text = "I will endeavor to learn more about $(entities[:topic])."
            # Trigger discovery loop for this topic
            # IggyDiscoveryLoop.run_sovereign_discovery_loop(iggy.kg, entities[:topic]) # Needs adaptation
            action_to_take = :initiate_learning
        else
            response_text = "What topic would you like me to learn about?"
        end
    elseif parsed_intent == :query_knowledge
        if haskey(entities, :topic)
            # Query KG for facts about the topic
            facts = IggyOntology.query_facts(iggy.kg, Symbol(entities[:topic]), nothing, nothing)
            if isempty(facts)
                response_text = "I don't have specific knowledge about $(entities[:topic]) yet, but I can try to learn about it."
            else
                response_text = "Here's what I know about $(entities[:topic]):\n"
                for (s,p,o) in facts
                    response_text *= "- $s $p $o\n"
                end
            end
            action_to_take = :report_knowledge
        else
            response_text = "What knowledge are you seeking?"
        end
    end

    # 3. ACT
    # This is where IGGY would perform actions based on the reasoned intent
    # For now, we return the response text
    iggy.last_response = response_text
    return response_text
end

# Placeholder for FeedbackModule struct
mutable struct FeedbackModule
    # Add fields for feedback mechanisms here
    function FeedbackModule()
        new()
    end
end

# Placeholder for IggyOntology.TYPE_AI_SYSTEM until the module is fully defined
module IggyOntology
    mutable struct KnowledgeGraph
        entities::Dict{Symbol, Symbol}
        relationships::Set{Tuple{Symbol, Symbol, Symbol}}
        function KnowledgeGraph()
            new(Dict{Symbol, Symbol}(), Set{Tuple{Symbol, Symbol, Symbol}}())
        end
    end

    function add_entity!(kg::KnowledgeGraph, entity::Symbol, type::Symbol)
        kg.entities[entity] = type
    end

    function add_fact!(kg::KnowledgeGraph, subject::Symbol, predicate::Symbol, object::Symbol)
        if !haskey(kg.entities, subject); add_entity!(kg, subject, :Unknown); end
        if !haskey(kg.entities, object); add_entity!(kg, object, :Unknown); end
        push!(kg.relationships, (subject, predicate, object))
    end

    function add_relationship!(kg::KnowledgeGraph, subject::Symbol, predicate::Symbol, object::Symbol)
        add_fact!(kg, subject, predicate, object)
    end

    function query_facts(kg::KnowledgeGraph, subject::Union{Symbol, Nothing}=nothing, predicate::Union{Symbol, Nothing}=nothing, object::Union{Symbol, Nothing}=nothing)
        results = Set{Tuple{Symbol, Symbol, Symbol}}()
        for fact in kg.relationships
            s, p, o = fact
            match_s = (subject === nothing || s == subject)
            match_p = (predicate === nothing || p == predicate)
            match_o = (object === nothing || o == object)
            if match_s && match_p && match_o
                push!(results, fact)
            end
        end
        return collect(results)
    end

    const TYPE_ASSET = :Asset
    const TYPE_USER = :User
    const TYPE_PROJECT = :Project
    const TYPE_LOCATION = :Location
    const TYPE_LITERAL = :Literal
    const TYPE_DOMAIN = :Domain
    const TYPE_AI_SYSTEM = :AISystem

    const PRED_IN_REGIME = :isInRegime
    const PRED_OWNS = :owns
    const PRED_PREDICTS = :predicts
    const PRED_CONNECTED_TO = :isConnectedTo
    const PRED_HAS_NAME = :hasName
    const PRED_LIVES_IN = :livesIn
    const PRED_LIKES = :likes
    const PRED_IS_ASSISTANT_OF = :isAssistantOf
    const PRED_HAS_CREATOR = :hasCreator
    const PRED_IS_AT = :isAt
    const PRED_CORRECTED_FACT_ABOUT = :correctedFactAbout
    const PRED_HAS_FOCUS_AREA = :hasFocusArea
    const PRED_HAS_PRIORITY = :hasPriority
    const PRED_HAS_URL = :hasURL
    const PRED_HAS_TITLE = :hasTitle
    const PRED_LEARNED_FROM = :learnedFrom
end
