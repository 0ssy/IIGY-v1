using SHA, Dates, JSON

# 1. THE VECTORIZED STORAGE FUNCTION
function update_vault(domain, focus_area, raw_data, priority)
    vault_path = "iggy_vault.jl"
    
    # Generate a unique hash for the knowledge piece to prevent duplicates
    entry_id = bytes2hex(sha256(raw_data))[1:10]
    timestamp = now()
    
    # Format the knowledge for the vault
    new_entry = """
    # Entry [$entry_id] | Domain: $domain | Priority: $priority
    # Learned on: $timestamp
    # Focus: $focus_area
    function knowledge_$entry_id()
        # Autonomous Insight:
        # $(replace(raw_data, "\n" => " "))
    end
    """
    
    # Append to iggy_vault.jl
    open(vault_path, "a") do f
        write(f, "\n" * new_entry)
    end
    
    println("✅ Vault Updated: [$domain] $focus_area stored with ID $entry_id.")
end

# 2. THE RECURSIVE FEEDBACK LOGIC
function process_search_results(results, domain_row)
    println("🧠 Filtering world data through Root Admin priorities...")
    
    for result in results
        # Logic: If priority is 'Critical', auto-ingest. 
        # If 'High' or 'Medium', flag for 'Root Approval'
        if domain_row.Creator_Priority == "Critical"
            update_vault(domain_row.Domain, domain_row.Focus_Area, result, "Critical")
        else
            println("⚠️ Pending Root Approval: Found data for $(domain_row.Focus_Area). Store? (y/n)")
            # In a fully autonomous loop, this could be a notification to your terminal
        end
    end
end