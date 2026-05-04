# iggy_discovery.jl
using CSV, DataFrames, HTTP, JSON, Dates

# 1. THE INGESTION ENGINE
function initialize_brain_schema(csv_path)
    schema = CSV.read(csv_path, DataFrame)
    println("🧠 IGGY Brain Schema Loaded.")
    return schema
end

# 2. THE REAL-TIME DISCOVERY LOOP
# This replaces simulation with live Google data access
function search_the_world(query, api_key, cx)
    url = "https://www.googleapis.com/customsearch/v1?q=$(query)&key=$(api_key)&cx=$(cx)"
    response = HTTP.get(url)
    results = JSON.parse(String(response.body))
    return results["items"]
end

include("iggy_ontology.jl")
include("iggy_transformer.jl")

# ─────────────────────────────────────────
# SOVEREIGN DISCOVERY LOOP
# ─────────────────────────────────────────
function run_sovereign_discovery_loop(kg::IggyOntology.KnowledgeGraph, domains_csv_path::String)
    println("IIGY: Initializing Sovereign Discovery Loop...")
    
    # This function will call the ingestion and search functions from iggy_transformer.jl
    # and integrate the results into the Knowledge Graph.
    IggyTransformer.run_sovereign_discovery(kg, domains_csv_path)

    println("IIGY: Sovereign Discovery Loop initialized.")
end


@async while true
    schema = initialize_brain_schema("iggy_global_knowledge.csv")
    run_sovereign_discovery_loop(schema, "iggy_global_knowledge.csv")
    sleep(3600) 
end