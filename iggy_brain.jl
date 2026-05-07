# ==============================================================================
# IGGY BRAIN v4.5 (MERGED) - SOVEREIGN INTELLIGENCE CORE
# ==============================================================================
# This module handles thinking, reasoning, and learning. It integrates with 
# LLMs (local and remote) and manages the system's knowledge base.
#
# Merge of:
#   - iggy_brain v4.0 (core thinking, learning, trade analysis)
#   - iggy_brain_merged logic (LLM backend integration, file/web learning)
#
# ==============================================================================

using JSON, Dates, HTTP, Printf

# --- Configuration ---

const BRAIN_LOG = "iggy_brain_v4.log"
const KNOWLEDGE_BASE_FILE = "iggy_knowledge_v4.json"

# --- Types ---

mutable struct BrainState
    last_thought::String
    knowledge_count::Int
    is_learning::Bool
    llm_backend::Symbol # :local, :remote
    learned_insights::Vector{String}
    trade_history::Vector{Dict}
end

brain_state = BrainState("", 0, true, :local, String[], Dict[])

# --- Core Logging ---

function log_brain_event(message::String)
    timestamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
    open(BRAIN_LOG, "a") do io
        println(io, "[$timestamp] $message")
    end
end

# --- Core Thinking Functions ---

function iggy_think(prompt::String; context::String="", trade_context::String="")
    log_brain_event("Thinking about: $prompt")
    
    # Combine prompt with trade context if available
    full_prompt = trade_context != "" ? "$prompt\n\nContext: $trade_context" : prompt
    
    try
        # Simulated logic for choosing backend and getting response
        # In production, this would call:
        #   - Local LLM via iggy_brain_py.py
        #   - Remote API (Claude, GPT, etc.)
        
        response = case_response(full_prompt)
        
        brain_state.last_thought = response
        push!(brain_state.learned_insights, response)
        
        log_brain_event("Thought completed: $(length(response)) chars")
        return response
    catch e
        log_brain_event("Error in thinking process: $e")
        return "I encountered an error while thinking. Please check my logs."
    end
end

function case_response(prompt::String)
    # Simple response patterns based on keyword matching
    lower_prompt = lowercase(prompt)
    
    if contains(lower_prompt, "mission")
        return "My current mission is to execute profitable trades while learning from market dynamics and optimizing my trading strategies over time."
    elseif contains(lower_prompt, "status") || contains(lower_prompt, "how are you")
        return "I'm operating normally. My brain is initialized, knowledge base is loaded, and I'm ready for trading and analysis."
    elseif contains(lower_prompt, "trade") || contains(lower_prompt, "profit")
        return "I analyze trades by evaluating entry points, risk management, and position sizing. My goal is consistent profitability with controlled drawdowns."
    elseif contains(lower_prompt, "learn") || contains(lower_prompt, "learn")
        return "I learn from multiple sources: file uploads, web pages, market data, and trade outcomes. Each new insight is added to my knowledge base."
    else
        return "I have processed your request: '$prompt'. Based on my current knowledge and trading experience, I recommend careful analysis of market conditions and risk management."
    end
end

# --- Learning Functions ---

function iggy_learn(data::Dict)
    if !brain_state.is_learning 
        return 
    end
    
    log_brain_event("Learning from new data...")
    try
        # Append to knowledge base
        kb = load_knowledge()
        key = "item_$(brain_state.knowledge_count + 1)"
        kb[key] = data
        save_knowledge(kb)
        
        brain_state.knowledge_count += 1
        log_brain_event("Successfully learned: $(data)")
    catch e
        log_brain_event("Error during learning: $e")
    end
end

function iggy_learn_file(path::String)
    log_brain_event("Learning from file: $path")
    try
        if !isfile(path)
            return "Error: File not found at $path"
        end
        
        content = read(path, String)
        data = Dict(
            "type" => "file",
            "path" => path,
            "size" => length(content),
            "timestamp" => string(now()),
            "preview" => content[1:min(500, end)]
        )
        
        iggy_learn(data)
        return "✅ Learned from file: $(basename(path)) ($(length(content)) characters)"
    catch e
        return "❌ Error learning from file: $e"
    end
end

function iggy_learn_url(url::String)
    log_brain_event("Learning from URL: $url")
    try
        response = HTTP.get(url, status_exception=false)
        
        if response.status != 200
            return "Error: Could not fetch URL (HTTP $(response.status))"
        end
        
        content = String(response.body)
        data = Dict(
            "type" => "url",
            "url" => url,
            "size" => length(content),
            "timestamp" => string(now()),
            "preview" => content[1:min(500, end)]
        )
        
        iggy_learn(data)
        return "✅ Learned from URL: $url"
    catch e
        return "❌ Error learning from URL: $e"
    end
end

# --- Trade Analysis ---

function iggy_analyze_trade(trade_data::Dict)
    log_brain_event("Analyzing trade performance...")
    push!(brain_state.trade_history, trade_data)
    
    prompt = "Analyze this trade: " * json(trade_data)
    analysis = iggy_think(prompt; context="TRADE_ANALYSIS")
    
    # Store analysis with trade
    trade_data["analysis"] = analysis
    
    return analysis
end

# --- Knowledge Base Management ---

function load_knowledge()
    if isfile(KNOWLEDGE_BASE_FILE)
        try
            return JSON.parsefile(KNOWLEDGE_BASE_FILE)
        catch
            return Dict()
        end
    else
        return Dict()
    end
end

function save_knowledge(kb::Dict)
    try
        open(KNOWLEDGE_BASE_FILE, "w") do io
            JSON.print(io, kb, 4)
        end
        log_brain_event("Knowledge base saved: $(length(kb)) entries")
    catch e
        log_brain_event("Error saving knowledge base: $e")
    end
end

# --- Status Display ---

function show_brain_status()
    println("🧠 IGGY Brain Status:")
    println("   Knowledge Base Entries: $(brain_state.knowledge_count)")
    println("   Learning Enabled: $(brain_state.is_learning)")
    println("   LLM Backend: $(brain_state.llm_backend)")
    println("   Learned Insights: $(length(brain_state.learned_insights))")
    println("   Trades Analyzed: $(length(brain_state.trade_history))")
end

function show_insights()
    if isempty(brain_state.learned_insights)
        println("No insights yet. Keep learning!")
        return
    end
    
    println("\n" * "="^60)
    println("💡 LEARNED INSIGHTS ($(length(brain_state.learned_insights)))")
    println("="^60)
    
    for (i, insight) in enumerate(brain_state.learned_insights[end-min(4, end-1):end])
        println("\n[$i] $insight")
    end
    println("\n" * "="^60 * "\n")
end

# --- Initialization ---

function init_brain()
    log_brain_event("Brain initializing...")
    kb = load_knowledge()
    brain_state.knowledge_count = length(kb)
    log_brain_event("Knowledge base loaded with $(brain_state.knowledge_count) entries.")
    println("✅ Brain initialized")
end

# --- Runtime State Management ---

function save_runtime_state!()
    log_brain_event("Saving runtime state...")
    try
        state_data = Dict(
            "brain_state" => Dict(
                "knowledge_count" => brain_state.knowledge_count,
                "learned_insights_count" => length(brain_state.learned_insights),
                "trades_analyzed" => length(brain_state.trade_history)
            ),
            "timestamp" => string(now())
        )
        
        open("iggy_runtime_state.json", "w") do io
            JSON.print(io, state_data, 2)
        end
        
        log_brain_event("Runtime state saved")
    catch e
        log_brain_event("Error saving runtime state: $e")
    end
end

# --- Entrypoint for Testing ---

if PROGRAM_FILE == @__FILE__
    init_brain()
    println(iggy_think("What is your current mission?"))
    show_brain_status()
end
