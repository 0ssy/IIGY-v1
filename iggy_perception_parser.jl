# iggy_perception_parser.jl
module IggyPerception
using ..IggyOntology

function parse_input_to_fact!(kg, input_data::Dict)
    # logic to map raw dict keys to Ontology symbols
    subject = get(input_data, :subject, :Unknown)
    predicate = get(input_data, :predicate, PRED_CONNECTED_TO)
    object = get(input_data, :object, :Unknown)
    
    # Validation and addition to KG
    println("👁️ Perception: Encoded ($subject, $predicate, $object)")
end
end