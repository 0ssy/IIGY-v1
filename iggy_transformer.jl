using HTTP, Gumbo, Cascadia, CSV, DataFrames, Dates, Printf

# ── ROBUST KNOWLEDGE INGESTION ──────────────────────────────────────────────
function ingest_domain_knowledge()
    println(">>> IIGY: Repairing and Syncing with CSV...")
    
    # We use 'quotechar' to handle those pesky commas in parentheses
    try
        df = CSV.read("iggy_global_knowledge.csv", DataFrame, quotechar='"', escapechar='\\')
        
        knowledge_map = []
        for row in eachrow(df)
            # Silently handle rows that might still be shifted
            area = ismissing(row.Focus_Area) ? "" : string(row.Focus_Area)
            priority = ismissing(row.Creator_Priority) ? "Low" : string(row.Creator_Priority)
            domain = ismissing(row.Domain) ? "General" : string(row.Domain)
            
            push!(knowledge_map, (area=area, priority=priority, domain=domain))
        end
        return knowledge_map
    catch e
        println("CRITICAL ERROR reading CSV: Ensure no stray commas exist.")
        return []
    end
end

# ── THE "HUMAN-LIKE" SEARCHER ───────────────────────────────────────────────
function seek_world_info(topic::String)
    # 1. Use the most basic search URL to avoid bot-triggering parameters
   search_url = "https://html.duckduckgo.com/html/?q=$(replace(topic, " " => "+"))"
    
    headers = [
        "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    ]
    
    try
        res = HTTP.get(search_url, headers)
        body = String(res.body)
        
        # DEBUG: If you keep getting 0 points, uncomment the next line to see what Google sees:
         write("debug_search.html", body) 

        html = parsehtml(body)
        results = String[]

        # 2. Broader Selectors: Google often changes classes. 
        # We will look for h3 (titles) and 'span' or 'div' that likely contain snippets.
        # DuckDuckGo HTML uses 'a.result__a' for titles and 'a.result__snippet' for descriptions
for n in eachmatch(sel"a.result__a, .result__snippet", html.root)
    txt = strip(nodeText(n))
    if length(txt) > 30
        push!(results, txt)
    end
end
        
        return results
    catch e
        return String[]
    end
end

# ── RUN SESSION ─────────────────────────────────────────────────────────────
function start_iggy_session()
    kb = ingest_domain_knowledge()
    
    println("="^60)
    println(" IIGY v1: KNOWLEDGE INGESTION PHASE ")
    println(" Location: Nairobi | Target: Tech & Business Context ")
    println("="^60)

    for item in kb
        # Skip empty areas and only focus on what matters to you
        if !isempty(item.area) && (item.priority == "Critical" || item.priority == "High")
            print(">>> Learning: $(item.area) ... ")
            
            data = seek_world_info("$(item.domain) $(item.area)")
            
            if !isempty(data)
                open("iggy_world_view.txt", "a") do f
                    write(f, "\n[$(now())] TOPIC: $(item.area)\n")
                    for point in data[1:min(2, length(data))]
                        write(f, "DATA: $point\n")
                    end
                end
                println("Success: Found $(length(data)) insights.")
            else
                println("Skipped (No clear data).")
            end
            
            # Anti-Ban Sleep: Makes it look like a student browsing
            sleep(rand(4.0:7.0)) 
        end
    end
    println("\n[FINISH] IIGY has completed her study session.")
end

start_iggy_session()