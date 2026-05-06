using CSV, DataFrames, HTTP, JSON, Dates

# ── NOTE ──────────────────────────────────────────────────────────────────────
# All functions here are TOP-LEVEL — there is no IggyDiscoveryLoop module.
# Call them directly:  run_sovereign_discovery_loop(kg, path)
# NOT:                 IggyDiscoveryLoop.run_sovereign_discovery_loop(...)
# ─────────────────────────────────────────────────────────────────────────────

include("iggy_ontology.jl")
include("iggy_transformer.jl")

# ─────────────────────────────────────────
# 1. INGESTION ENGINE
# ─────────────────────────────────────────

"""
    initialize_brain_schema(csv_path) -> DataFrame

Load the global knowledge CSV and return it as a DataFrame.
"""
function initialize_brain_schema(csv_path::String)
    schema = CSV.read(csv_path, DataFrame)
    println("🧠 IGGY Brain Schema Loaded.")
    return schema
end

# ─────────────────────────────────────────
# 2. WEB SEARCH (Google Custom Search)
# ─────────────────────────────────────────

"""
    search_the_world(query, api_key, cx) -> Vector

Return raw search-result items from Google Custom Search API.
"""
function search_the_world(query::String, api_key::String, cx::String)
    url      = "https://www.googleapis.com/customsearch/v1?q=$(query)&key=$(api_key)&cx=$(cx)"
    response = HTTP.get(url)
    results  = JSON.parse(String(response.body))
    return get(results, "items", [])
end

# ─────────────────────────────────────────
# 3. SOVEREIGN DISCOVERY LOOP
# ─────────────────────────────────────────

"""
    run_sovereign_discovery_loop(kg, domains_csv_path)

Ingest the domains CSV and feed discoveries into the Knowledge Graph via
IggyTransformer.  Called directly — NOT through a module prefix.
"""
function run_sovereign_discovery_loop(
        kg              :: IggyOntology.KnowledgeGraph,
        domains_csv_path :: String)

    println("IGGY: Initialising Sovereign Discovery Loop…")
    IggyTransformer.run_sovereign_discovery(kg, domains_csv_path)
    println("IGGY: Sovereign Discovery Loop complete.")
end

# ─────────────────────────────────────────
# 4. BACKGROUND REFRESH  (runs when this file is included)
# ─────────────────────────────────────────
# Refreshes the brain schema every hour.
# Uses a local KG instance so it doesn't block the executive's KG.
@async while true
    try
        schema = initialize_brain_schema("iggy_global_knowledge.csv")
        # schema is a DataFrame; adapt downstream as needed
    catch e
        println("Brain schema refresh error: $e")
    end
    sleep(3600)
end
