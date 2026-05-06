# ==============================================================================
# iggy_discovery_loop.jl  — Sovereign Discovery Loop
#
# FIX (v3.1): The entire file is now wrapped in  module IggyDiscoveryLoop
# so that iggy_executive_v3.jl's call to
#   IggyDiscoveryLoop.run_sovereign_discovery_loop(iggy.kg, "domains_clean.csv")
# resolves without UndefVarError.
#
# Nothing else changed — all logic is identical to the original.
# ==============================================================================

module IggyDiscoveryLoop
using Random

export run_sovereign_discovery_loop

using Dates, JSON, HTTP

# ── Helpers ───────────────────────────────────────────────────────────────────

"""
    load_domains(csv_path) → Vector{String}

Read a one-column CSV (no header) of domain / topic strings.
Returns an empty vector on any error so the loop keeps running.
"""
function load_domains(csv_path::String) :: Vector{String}
    isfile(csv_path) || return String[]
    try
        lines = readlines(csv_path)
        return [strip(l) for l in lines if !isempty(strip(l))]
    catch e
        @warn "Discovery: could not read $csv_path — $e"
        return String[]
    end
end

"""
    fetch_page(url; timeout=15) → Union{String, Nothing}

HTTP GET with a timeout.  Returns the body text or nothing on failure.
"""
function fetch_page(url::String; timeout::Int = 15) :: Union{String, Nothing}
    try
        resp = HTTP.get(url; readtimeout=timeout, status_exception=false)
        resp.status == 200 || return nothing
        return String(resp.body)
    catch
        return nothing
    end
end

"""
    strip_html(raw) → String

Very light tag stripper — good enough for knowledge chunking.
"""
function strip_html(raw::String) :: String
    no_tags  = replace(raw,  r"<[^>]+>" => " ")
    no_space = replace(no_tags, r"\s+"  => " ")
    return strip(no_space)
end

"""
    chunk_text(text; max_chars=600) → Vector{String}

Split text into overlapping chunks for vector storage.
"""
function chunk_text(text::String; max_chars::Int = 600) :: Vector{String}
    words  = split(text)
    chunks = String[]
    buf    = String[]
    chars  = 0
    for w in words
        push!(buf, w)
        chars += length(w) + 1
        if chars >= max_chars
            push!(chunks, join(buf, " "))
            # 20 % overlap
            overlap = max(1, length(buf) ÷ 5)
            buf   = buf[end-overlap+1:end]
            chars = sum(length(b) + 1 for b in buf)
        end
    end
    isempty(buf) || push!(chunks, join(buf, " "))
    return filter(c -> length(c) >= 80, chunks)
end

# ── DDG search ────────────────────────────────────────────────────────────────

"""
    ddg_search(query; n=4) → Vector{String}

DuckDuckGo instant-answer scrape.  Returns up to *n* result URLs.
Falls back to empty on any error so the loop never crashes.
"""
function ddg_search(query::String; n::Int = 4) :: Vector{String}
    urls = String[]
    try
        encoded = HTTP.URIs.escapeuri(query)
        raw = fetch_page("https://html.duckduckgo.com/html/?q=$encoded")
        isnothing(raw) && return urls
        # Extract href="//duckduckgo.com/l/?uddg=<encoded-url>"
        for m in eachmatch(r"uddg=([^&\"]+)", raw)
            url = HTTP.URIs.unescapeuri(m.captures[1])
            startswith(url, "http") && push!(urls, url)
            length(urls) >= n && break
        end
    catch e
        @warn "DDG search error for '$query': $e"
    end
    return urls
end

# ── Knowledge storage bridge ──────────────────────────────────────────────────

"""
    store_chunks(chunks, source, topic)

Calls iggy_brain.jl's store_to_knowledge_base if it is loaded in Main.
Safe to call even if not loaded — just prints a warning.
"""
# Dedup guard — prevents parallel tasks storing the same URL twice
const _STORED_URLS = Set{String}()
const _STORED_LOCK  = ReentrantLock()

function store_chunks(chunks::Vector{String}, source::String, topic::String)
    # Skip URL if already stored by another concurrent task
    _already = lock(_STORED_LOCK) do
        source in _STORED_URLS ? true : (push!(_STORED_URLS, source); false)
    end
    _already && return 0
    n = 0
    for chunk in chunks
        try
            # store_to_knowledge_base is defined in iggy_brain.jl (Main scope)
            Base.invokelatest(Main.store_to_knowledge_base, chunk; source=source)
            n += 1
        catch e
            # Brain not loaded or storage error — non-fatal
        end
    end
    println("  ✓ $source → $n chunks stored (topic: $topic)")
    return n
end

# ── Single discovery cycle ────────────────────────────────────────────────────

"""
    discovery_cycle(domains) → (pages_fetched, chunks_added)

For each domain / topic string:
  1. DDG-search it
  2. Fetch each result page
  3. Chunk and store the text
"""
function discovery_cycle(domains::Vector{String}) :: Tuple{Int,Int}
    pages   = 0
    chunks  = 0
    shuffle_idx = randperm(length(domains))   # random order each cycle

    for idx in shuffle_idx
        topic = domains[idx]
        println("  [Discovery] DDG '$topic'")
        urls = ddg_search(topic; n=4)
        isempty(urls) && continue

        for url in urls
            raw = fetch_page(url)
            isnothing(raw) && continue
            text   = strip_html(raw)
            length(text) < 200 && continue
            cs     = chunk_text(text)
            added  = store_chunks(cs, url, topic)
            pages += 1
            chunks += added
        end

        sleep(rand(1:3))   # be polite to servers
    end

    return pages, chunks
end

# ── Public entry point ────────────────────────────────────────────────────────

"""
    run_sovereign_discovery_loop(kg, domains_csv; sleep_seconds=180)

Main loop called by iggy_executive_v3.jl.  Runs forever, one cycle per
*sleep_seconds*.  Errors inside a cycle are caught so the loop never dies.
"""
function run_sovereign_discovery_loop(
        kg,                        # IggyOntology.KnowledgeGraph (unused for now, reserved)
        domains_csv::String = "domains_clean.csv";
        sleep_seconds::Int  = 180,
)
    println("🕷  IGGY Sovereign Discovery Loop started")
    domains = load_domains(domains_csv)
    isempty(domains) && @warn "Discovery: no domains loaded from $domains_csv"

    cycle = 0
    while true
        cycle += 1
        println("\n[Discovery] Cycle $cycle — $(Dates.format(now(), "HH:MM:SS"))")

        try
            pages, chunks = discovery_cycle(domains)
            println("[Discovery] Cycle done | pages:$pages chunks_added:$chunks")
        catch e
            println("⚠️  Discovery cycle error: $e")
        end

        println("[Discovery] ⏳ Sleeping $(sleep_seconds)s…")
        sleep(sleep_seconds)

        # Reload domain list each cycle so the CSV can be edited live
        new_domains = load_domains(domains_csv)
        isempty(new_domains) || (domains = new_domains)
    end
end

end  # module IggyDiscoveryLoop
