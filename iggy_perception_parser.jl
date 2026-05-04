module IggyPerception

using ..IggyOntology # Assuming IggyOntology is in the parent module

# A simple keyword-based intent recognition for now
function parse_user_input(input_text::String, kg::IggyOntology.KnowledgeGraph)
    lower_input = lowercase(input_text)
    intent = :unknown
    entities = Dict{Symbol, Any}()

    # General greetings
    if occursin("hello", lower_input) || occursin("hi iggy", lower_input) || occursin("hey iggy", lower_input)
        intent = :general_greeting
    elseif occursin("how are you", lower_input)
        intent = :query_wellbeing
    elseif occursin("who are you", lower_input)
        intent = :query_identity
    elseif occursin("what can you do", lower_input)
        intent = :query_capabilities
    end

    # Trading bot related queries
    if occursin("trading status", lower_input) || occursin("how are we doing", lower_input) || occursin("current balance", lower_input)
        intent = :query_cns_status
    elseif occursin("trade history", lower_input) || occursin("past trades", lower_input)
        intent = :query_cns_trade_history
    elseif occursin("open positions", lower_input) || occursin("active trades", lower_input)
        intent = :query_cns_open_positions
    end

    # Learning/Knowledge related queries
    if occursin("tell me about", lower_input)
        intent = :query_knowledge
        # Simple entity extraction for now: assumes the topic is after "tell me about"
        match_obj = match(r"tell me about (.+)", lower_input)
        if match_obj !== nothing
            entities[:topic] = strip(match_obj.captures[1])
        end
    elseif occursin("what is", lower_input)
        intent = :query_knowledge
        match_obj = match(r"what is (.+)", lower_input)
        if match_obj !== nothing
            entities[:topic] = strip(match_obj.captures[1])
        end
    elseif occursin("learn about", lower_input)
        intent = :learn_fact
        match_obj = match(r"learn about (.+)", lower_input)
        if match_obj !== nothing
            entities[:topic] = strip(match_obj.captures[1])
        end
    end

    # Extract user name if present (simple example)
    match_name = match(r"my name is (\w+)", lower_input)
    if match_name !== nothing
        entities[:user_name] = match_name.captures[1]
    end

    return intent, entities
end

# Placeholder for more advanced parsing that directly adds facts to KG
function parse_input_to_fact!(kg::IggyOntology.KnowledgeGraph, input_data::Dict)
    # This logic would map raw dict keys to Ontology symbols
    subject = get(input_data, :subject, :Unknown)
    predicate = get(input_data, :predicate, IggyOntology.PRED_CONNECTED_TO)
    object = get(input_data, :object, :Unknown)

    # Validation and addition to KG
    println("Perception: Encoded ($subject, $predicate, $object)")
    # IggyOntology.add_fact!(kg, subject, predicate, object) # Uncomment when add_fact! is defined in ontology
end

end # module IggyPerception
