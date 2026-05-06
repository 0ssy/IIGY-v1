using HTTP, Gumbo, Cascadia, CSV, DataFrames, Dates, Printf

# ── NOTE ──────────────────────────────────────────────────────────────────────
# Do NOT include iggy_ontology.jl here.
# iggy_executive.jl is the single entry point that loads all modules first.
# Re-including iggy_ontology.jl creates a SECOND definition of
# IggyOntology.KnowledgeGraph — a different type to the first — causing
# "Cannot convert KnowledgeGraph to KnowledgeGraph" MethodErrors at runtime.
# ─────────────────────────────────────────────────────────────────────────────

module IggyTransformer

# IggyOntology is defined in Main (loaded by iggy_executive.jl before this file).
# Modules have isolated scope, so we must explicitly import it.
import Main.IggyOntology

# ─────────────────────────────────────────
# DOMAIN KNOWLEDGE INGESTION
# ─────────────────────────────────────────

"""
    ingest_domain_knowledge(kg, domains_csv_path)

Read the domains CSV and add each row as facts into the Knowledge Graph.
"""
function ingest_domain_knowledge(kg::IggyOntology.KnowledgeGraph, domains_csv_path::String)
    println("IIGY: Repairing and Syncing with Knowledge Domains…")
    knowledge_map = []

    try
        df = CSV.read(domains_csv_path, DataFrame, quotechar='"', escapechar='\\')

        for row in eachrow(df)
            area     = ismissing(row.Focus_Area)        ? ""        : string(row.Focus_Area)
            priority = ismissing(row.Creator_Priority)  ? "Low"     : string(row.Creator_Priority)
            domain   = ismissing(row.Domain)            ? "General" : string(row.Domain)

            IggyOntology.add_entity!(kg, Symbol(domain), IggyOntology.TYPE_DOMAIN)
            IggyOntology.add_fact!(kg, Symbol(domain), IggyOntology.PRED_HAS_FOCUS_AREA, Symbol(area))
            IggyOntology.add_fact!(kg, Symbol(domain), IggyOntology.PRED_HAS_PRIORITY,   Symbol(priority))

            push!(knowledge_map, (area=area, priority=priority, domain=domain))
        end
    catch e
        println("CRITICAL ERROR reading domains CSV: $e")
        return []
    end

    println("IIGY: Knowledge domains ingested successfully.")
    return knowledge_map
end

# ─────────────────────────────────────────
# WEB SEARCHER (stealthy crawler)
# ─────────────────────────────────────────

"""
    seek_world_info(topic) -> Vector of (title, url) NamedTuples

Search DuckDuckGo and return result links for `topic`.
"""
function seek_world_info(topic::String)
    println("IIGY: Seeking world info on: $topic")

    search_url = "https://html.duckduckgo.com/html/?q=$(replace(topic, " " => "+"))"

    headers = [
        "User-Agent"                => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36",
        "Accept"                    => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language"           => "en-US,en;q=0.9",
        "Connection"                => "keep-alive",
        "Upgrade-Insecure-Requests" => "1",
    ]

    try
        response = HTTP.get(search_url, headers=headers, redirect=true, readtimeout=10)
        html_doc = Gumbo.parsehtml(String(response.body))
        results  = []

        for link_node in eachmatch(Cascadia.sel("a.result__url"), html_doc.root)
            href = Gumbo.getattr(link_node, "href")
            title_nodes = collect(eachmatch(Cascadia.sel("a.result__a"), link_node))
            title = isempty(title_nodes) ? "No Title" : Gumbo.text(first(title_nodes))
            if href !== nothing && startswith(href, "http")
                push!(results, (title=title, url=href))
            end
        end

        println("IIGY: Found $(length(results)) results for '$topic'.")
        return results
    catch e
        println("IIGY: Error seeking world info for '$topic': $e")
        return []
    end
end

# ─────────────────────────────────────────
# RAW DATA → KG FACTS  (placeholder)
# ─────────────────────────────────────────

function transform_raw_data_to_facts!(kg::IggyOntology.KnowledgeGraph,
                                      raw_data::String,
                                      source_url::String)
    println("IIGY: Transforming raw data from $source_url into facts… (conceptual)")
    # Future: NLP extraction here
end

# ─────────────────────────────────────────
# SOVEREIGN DISCOVERY  (called by iggy_discovery_loop.jl)
# ─────────────────────────────────────────

"""
    run_sovereign_discovery(kg, domains_csv_path)

Ingest knowledge domains and crawl the web for each domain topic.
"""
function run_sovereign_discovery(kg::IggyOntology.KnowledgeGraph, domains_csv_path::String)
    println("IIGY: Starting Sovereign Discovery Loop…")
    knowledge_domains = ingest_domain_knowledge(kg, domains_csv_path)

    for domain_info in knowledge_domains
        search_results = seek_world_info(domain_info.domain)

        for result in search_results
            println("  Discovered: $(result.title)  →  $(result.url)")
            url_sym = Symbol(result.url)
            IggyOntology.add_entity!(kg, url_sym, IggyOntology.TYPE_LITERAL)
            IggyOntology.add_fact!(kg, Symbol(domain_info.domain), IggyOntology.PRED_LEARNED_FROM, url_sym)
            IggyOntology.add_fact!(kg, url_sym, IggyOntology.PRED_HAS_TITLE, Symbol(result.title))
        end
    end

    println("IIGY: Sovereign Discovery Loop Finished.")
end

end  # module IggyTransformer
