module IggyOntology

# Entity Types
const TYPE_ASSET = :Asset
const TYPE_USER = :User
const TYPE_PROJECT = :Project
const TYPE_LOCATION = :Location
const TYPE_LITERAL = :Literal # For values like numbers, strings
const TYPE_DOMAIN = :Domain # For knowledge domains

# Predicates (Relationships)
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

# ─────────────────────────────────────────
# KNOWLEDGE GRAPH
# ─────────────────────────────────────────
mutable struct KnowledgeGraph
    entities::Dict{Symbol, Symbol} # Entity => Type
    facts::Set{Tuple{Symbol, Symbol, Symbol}} # (Subject, Predicate, Object)
    
    function KnowledgeGraph()
        new(Dict{Symbol, Symbol}(), Set{Tuple{Symbol, Symbol, Symbol}}())
    end
end

function add_entity!(kg::KnowledgeGraph, entity::Symbol, type::Symbol)
    kg.entities[entity] = type
    println("KG: Added entity $entity of type $type")
end

function add_fact!(kg::KnowledgeGraph, subject::Symbol, predicate::Symbol, object::Symbol)
    # Ensure entities exist or add them as unknown type for now
    if !haskey(kg.entities, subject); add_entity!(kg, subject, :Unknown); end
    if !haskey(kg.entities, object); add_entity!(kg, object, :Unknown); end

    push!(kg.facts, (subject, predicate, object))
    println("KG: Added fact ($subject, $predicate, $object)")
end

function query_facts(kg::KnowledgeGraph, subject::Union{Symbol, Nothing}=nothing, predicate::Union{Symbol, Nothing}=nothing, object::Union{Symbol, Nothing}=nothing)
    results = Set{Tuple{Symbol, Symbol, Symbol}}()
    for fact in kg.facts
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

println("IGGY: Ontology definitions and KnowledgeGraph loaded.")

end # module IggyOntology
