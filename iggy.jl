# ==============================================================================
# IGGY EXECUTIVE v4.5 (MERGED) - SOVEREIGN COMMAND CORE
# ==============================================================================
# Merge of:
#   iggy_executive_v4.0 → streamlined v4.0 architecture, cleaner commands
#   iggy_executive_v3.0 → comprehensive threading, browser server, REPL,
#                        vision loop, discovery loop, status monitoring
#
# This is the main entry point for IGGY. It orchestrates all modules:
# CNS (Trading), Vision (Learning), LLM (Thinking), and Discovery (Knowledge).
#
# Run: julia --threads 8 iggy_executive_merged.jl
#
# Thread map:
#   Thread 1-3  → CNS trading (one per symbol via @spawn)
#   Thread 4    → Vision loop (screen learning, file watcher)
#   Thread 5    → Status monitor (periodic reporting)
#   Main thread → Conversation REPL + browser chat server (port 8765)
#
# Commands (type in REPL):
#   exit          — shut down system
#   status        — show current CNS + brain status
#   insights      — show learned trading rules
#   read <path>   — teach IGGY a file
#   url <link>    — teach IGGY a web page
#   do <task>     — execute a laptop task (assistant)
#   think <query> — ask IGGY to think about something
#   help          — show available commands
# ==============================================================================

using Dates, JSON, Printf, HTTP

# ──────────────────────────────────────────────────────────────────────────
# INCLUDE ORDER MATTERS — Dependencies first
# ──────────────────────────────────────────────────────────────────────────

include("iggy_persistence.jl")
include("iggy_ontology.jl")
include("iggy_inference_engine.jl")
include("iggy_graph_traversal.jl")
include("iggy_perception_parser.jl")
include("iggy_cns_core.jl")           # Trading engine (Capital, Strategy, Asset, Position)
include("iggy_bridge.jl")             # IGGYState, initialize_iggy_state
include("iggy_brain.jl")              # LLM brain (iggy_think, iggy_learn, etc.)
include("iggy_discovery_loop.jl")     # World knowledge acquisition
include("iggy_vision.jl")             # Screen learning & perception

# ──────────────────────────────────────────────────────────────────────────
# STUB FUNCTIONS - Fix undefined references
# ──────────────────────────────────────────────────────────────────────────

# Brain & Learning Stubs
function init_brain()
    println("✅ Brain initialized (stub)")
    return true
end

function iggy_think(query::String; trade_context="")
    if isempty(trade_context)
        return "Thinking about: $query"
    else
        return "Thinking about: $query\n\nContext:\n$trade_context"
    end
end

function iggy_learn_file(path::String)
    if !isfile(path)
        return "❌ File not found: $path"
    end
    try
        content = read(path, String)
        lines = length(split(content, '\n'))
        return "✅ Learned from $path ($lines lines)"
    catch e
        return "❌ Error reading $path: $e"
    end
end

function iggy_learn_url(url::String)
    return "✅ Would fetch and learn from: $url (not yet implemented)"
end

function show_brain_status()
    println("Brain Status: Ready")
    println("  Mode: Active")
    println("  Context: Available")
end

# Knowledge & Insights Stubs
const IGGY_INSIGHTS = String[]

function show_insights()
    if isempty(IGGY_INSIGHTS)
        println("📚 No insights learned yet.")
        println("   Trade and IGGY will learn patterns automatically.")
    else
        println("📚 Learned Insights:")
        for (i, insight) in enumerate(IGGY_INSIGHTS)
            println("  $i. $insight")
        end
    end
end

function record_insight(insight::String)
    push!(IGGY_INSIGHTS, insight)
end

# Adaptive Trading Stubs
mutable struct AdaptiveMemory
    outcomes    :: Vector{Float64}
    pnl_history :: Vector{Float64}
    cooldown    :: Int
end

AdaptiveMemory() = AdaptiveMemory(Float64[], Float64[], 0)

function adaptive_bias(mem::AdaptiveMemory)
    if isempty(mem.outcomes)
        return 0.5
    end
    return mean(mem.outcomes)
end

function record_trade_outcome(symbol::String, outcome::Float64)
    if haskey(adapt_mem, symbol)
        push!(adapt_mem[symbol].outcomes, outcome)
        push!(adapt_mem[symbol].pnl_history, outcome)
    end
end

# CNS Trading Loop Stub
function cns_main_loop_step(capital::Capital, strat::Strategy,
                            assets::Dict{String,Asset},
                            brains::Dict{String,Brain},
                            positions::Dict{String,Position},
                            kline_channel::Channel)
    if isready(kline_channel)
        try
            kline = take!(kline_channel)
        catch
        end
    end
    return nothing
end

# Persistence Stubs
function save_runtime_state!()
    try
        state = Dict(
            "successful_trades" => successful_trades[],
            "failed_trades"     => failed_trades[],
            "ready_notice_sent" => ready_notice_sent[],
            "saved_at"          => string(now()),
        )
        open("iggy_runtime_state.json", "w") do f
            JSON.print(f, state)
        end
        return true
    catch e
        println("⚠️  Error saving state: $e")
        return false
    end
end

function load_runtime_state!()
    state_file = "iggy_runtime_state.json"
    if !isfile(state_file)
        return false
    end
    try
        state = JSON.parsefile(state_file)
        successful_trades[] = Int(get(state, "successful_trades", 0))
        failed_trades[]     = Int(get(state, "failed_trades", 0))
        ready_notice_sent[] = Bool(get(state, "ready_notice_sent", false))
        return true
    catch e
        println("⚠️  Error loading state: $e")
        return false
    end
end

# Feedback Module Stub
mutable struct FeedbackModule
    last_feedback::String
    feedback_count::Int
    FeedbackModule() = new("", 0)
end

# ──────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────

const IGGY_VERSION = "4.5-Merged"
if !@isdefined(LOG_FILE)
    const LOG_FILE = "iggy_executive_v4.5.log"
end
const CHAT_PORT = 8765

# Ensure CNS globals are available
if !@isdefined(successful_trades)
    successful_trades = Ref(0)
    failed_trades = Ref(0)
end

if !@isdefined(open_pos)
    open_pos = Dict()
end

if !@isdefined(SYMBOLS)
    SYMBOLS = ["BTCUSDT", "ETHUSDT", "SOLUSDT"]
end

if !@isdefined(adapt_mem)
    adapt_mem = Dict{String, AdaptiveMemory}()
    for s in SYMBOLS
        adapt_mem[s] = AdaptiveMemory()
    end
end

if !@isdefined(total_pnl)
    total_pnl = Dict{String, Float64}()
    for s in SYMBOLS
        total_pnl[s] = 0.0
    end
end

if !@isdefined(ready_notice_sent)
    ready_notice_sent = Ref(false)
end

# Browser chat channels
const CHAT_MSGS = Channel{String}(50)
const CHAT_RESPS = Channel{String}(50)

# ──────────────────────────────────────────────────────────────────────────
# SYSTEM STATE
# ──────────────────────────────────────────────────────────────────────────

mutable struct IGGYSystemState
    is_running::Bool
    start_time::DateTime
    tasks_completed::Int
    active_threads::Vector{Task}
    last_error::Union{Nothing, Exception}
end

global_state = IGGYSystemState(true, now(), 0, Task[], nothing)

# ──────────────────────────────────────────────────────────────────────────
# LOGGING & STATUS
# ──────────────────────────────────────────────────────────────────────────

function log_system_event(message::String)
    timestamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
    open(LOG_FILE, "a") do io
        println(io, "[$timestamp] $message")
    end
    println("🔔 IGGY: $message")
end

function show_status()
    uptime = now() - global_state.start_time
    println("\n" * "="^60)
    println("🤖 IGGY v$IGGY_VERSION STATUS")
    println("="^60)
    println("Uptime: $uptime")
    println("Tasks Completed: $(global_state.tasks_completed)")
    println("Active Threads: $(length(global_state.active_threads))")
    
    try
        show_brain_status()
    catch
    end
    
    println("="^60 * "\n")
end

# ──────────────────────────────────────────────────────────────────────────
# BROWSER CHAT SERVER
# ──────────────────────────────────────────────────────────────────────────

function start_browser_server(iggy::IGGYState)
    @async begin
        try
            HTTP.serve("0.0.0.0", CHAT_PORT) do req
                local current_iggy = iggy
                
                if req.method == "OPTIONS"
                    return HTTP.Response(200, [
                        "Access-Control-Allow-Origin"  => "*",
                        "Access-Control-Allow-Methods" => "POST, GET, OPTIONS",
                        "Access-Control-Allow-Headers" => "Content-Type"
                    ])
                end

                if req.method == "POST" && req.target == "/chat"
                    body = JSON.parse(String(req.body))
                    user_msg = get(body, "message", "")

                    if !isempty(user_msg)
                        ctx = build_trade_context_string(current_iggy)
                        response = iggy_think(user_msg; trade_context=ctx)

                        return HTTP.Response(200,
                            ["Content-Type" => "application/json",
                             "Access-Control-Allow-Origin" => "*"],
                            body=JSON.json(Dict("response" => response))
                        )
                    end

                elseif req.method == "GET" && req.target == "/status"
                    stats = get_iggy_stats(current_iggy)
                    return HTTP.Response(200,
                        ["Content-Type" => "application/json",
                         "Access-Control-Allow-Origin" => "*"],
                        body=JSON.json(stats)
                    )
                end

                return HTTP.Response(404, "Not found")
            end
        catch e
            println("⚠️  Browser server error: $e")
        end
    end
    println("🌐 Browser chat server → http://localhost:$CHAT_PORT/chat")
end

# ──────────────────────────────────────────────────────────────────────────
# STATUS HELPERS
# ──────────────────────────────────────────────────────────────────────────

function build_trade_context_string(iggy::IGGYState)::String
    lines = String[]
    try
        capital = iggy.cns_capital
        push!(lines, @sprintf("Balance: %.2f | DD: %.2f%%",
            capital.balance, capital.dd * 100))

        wins = successful_trades[]
        total = wins + failed_trades[]
        wr = total == 0 ? 0.0 : wins / total
        push!(lines, @sprintf("Trades: %d (%.1f%% win)", total, 100 * wr))

        if !isempty(open_pos)
            push!(lines, "Open: " * join(
                ["$(s): $(p.side)" for (s, p) in open_pos], ", "
            ))
        end
    catch
        push!(lines, "Status unavailable")
    end
    return join(lines, "\n")
end

function get_iggy_stats(iggy::IGGYState)::Dict
    try
        capital = iggy.cns_capital
        wins = successful_trades[]
        total = wins + failed_trades[]
        return Dict(
            "balance" => capital.balance,
            "drawdown" => round(capital.dd * 100, digits=2),
            "wins" => wins,
            "losses" => failed_trades[],
            "win_rate" => total > 0 ? round(100.0 * wins / total, digits=1) : 0.0,
            "open_positions" => length(open_pos),
            "insights" => length(IGGY_INSIGHTS),
            "timestamp" => string(now())
        )
    catch
        return Dict("error" => "Stats unavailable")
    end
end

function push_chat_stats(iggy::IGGYState)
    stats = get_iggy_stats(iggy)
    if !haskey(stats, "error")
        @printf("📊 [%s] Balance:%.2f | DD:%.1f%% | Wins:%d/%d | Open:%d | Insights:%d\n",
            Dates.format(now(), "HH:MM:SS"),
            stats["balance"], stats["drawdown"],
            stats["wins"], stats["wins"] + stats["losses"],
            stats["open_positions"], stats["insights"])
    end
end

# ──────────────────────────────────────────────────────────────────────────
# CNS WEBSOCKET RUNNER
# ──────────────────────────────────────────────────────────────────────────

function cns_main_loop_runner(capital::Capital, strat::Strategy,
                               assets::Dict{String,Asset},
                               brains::Dict{String,Brain},
                               positions::Dict{String,Position},
                               iggy::IGGYState)
    kline_channel = Channel(100)
    
    println("🧠 CNS runner started (stub mode - WebSocket disabled)")
    # WebSocket would go here
    return nothing
end

# ──────────────────────────────────────────────────────────────────────────
# STATUS MONITOR
# ──────────────────────────────────────────────────────────────────────────

function run_status_monitor(iggy::IGGYState)
    @async begin
        while true
            sleep(60)
            push_chat_stats(iggy)
        end
    end
end

# ──────────────────────────────────────────────────────────────────────────
# VISION LOOP
# ──────────────────────────────────────────────────────────────────────────

function start_vision(iggy::IGGYState)
    @async begin
        try
            if @isdefined(run_vision_loop)
                run_vision_loop()
            else
                println("ℹ️  iggy_vision.jl not loaded — screen learning disabled")
            end
        catch e
            println("⚠️  Vision loop error: $e")
        end
    end
end

# ──────────────────────────────────────────────────────────────────────────
# DISCOVERY LOOP
# ──────────────────────────────────────────────────────────────────────────

function start_discovery(iggy::IGGYState)
    @async begin
        println("🌍 Discovery loop started (stub mode)")
    end
end

# ──────────────────────────────────────────────────────────────────────────
# ASSISTANT TASKS
# ──────────────────────────────────────────────────────────────────────────

function run_assistant_task(task_description::String)
    log_system_event("Executing assistant task: $task_description")
    try
        response = iggy_think("Execute this task: $task_description")
        log_system_event("Task response: $response")
        global_state.tasks_completed += 1
        return response
    catch e
        log_system_event("Error executing task: $e")
        return "Error: $e"
    end
end

# ──────────────────────────────────────────────────────────────────────────
# CONVERSATION REPL
# ──────────────────────────────────────────────────────────────────────────

function run_repl(iggy::IGGYState)
    println("\n" * "="^60)
    println("  IGGY v$IGGY_VERSION — Type to talk.")
    println("  Commands: exit | status | insights | help")
    println("  'read <path>' to learn a file | 'url <link>' to learn a page")
    println("  'do <task>' to execute | 'think <query>' to reason")
    println("="^60 * "\n")

    while true
        print("You > ")
        raw = try
            readline()
        catch e
            if isa(e, EOFError)
                "exit"
            else
                ""
            end
        end

        input = strip(raw)
        isempty(input) && continue

        if lowercase(input) == "exit"
            println("IGGY > Goodbye. Saving state...")
            save_runtime_state!()
            break

        elseif lowercase(input) == "status"
            println(build_trade_context_string(iggy))
            show_status()
            continue

        elseif lowercase(input) == "insights"
            show_insights()
            continue

        elseif lowercase(input) == "help"
            println("Available commands:")
            println("  status         — show current balance and trades")
            println("  insights       — show learned trading rules")
            println("  read <path>    — teach IGGY a file")
            println("  url <link>     — teach IGGY a web page")
            println("  do <task>      — execute a laptop task")
            println("  think <query>  — ask IGGY to think about something")
            println("  exit           — shut down")
            println("\nOr just type to chat with IGGY!")
            continue

        elseif startswith(lowercase(input), "read ")
            path = strip(input[6:end])
            println("📄 Learning from: $path")
            result = iggy_learn_file(path)
            println("IGGY > $result")
            continue

        elseif startswith(lowercase(input), "url ")
            url = strip(input[5:end])
            println("🌐 Fetching: $url")
            result = iggy_learn_url(url)
            println("IGGY > $result")
            continue

        elseif startswith(lowercase(input), "do ")
            task = strip(input[4:end])
            println("🤖 Executing task...")
            result = run_assistant_task(task)
            println("IGGY > $result")
            continue

        elseif startswith(lowercase(input), "think ")
            query = strip(input[7:end])
            println("🧠 Thinking...")
            response = iggy_think(query)
            println("IGGY > $response\n")
            continue
        end

        ctx = build_trade_context_string(iggy)
        response = iggy_think(input; trade_context=ctx)
        println("IGGY > $response\n")

        yield()
    end
end

# ──────────────────────────────────────────────────────────────────────────
# MAIN INITIALIZATION & RUNNER
# ──────────────────────────────────────────────────────────────────────────

function run_executive_merged()
    log_system_event("IGGY v$IGGY_VERSION initializing...")

    try
        iggy = initialize_iggy_state()
        log_system_event("State initialized")
    catch e
        log_system_event("State initialization warning: $e (continuing with minimal state)")
        iggy = IGGYState(
            IggyOntology.KnowledgeGraph(),
            FeedbackModule(),
            Capital(1000.0, 0.0, 1000.0, 0.0, 1000.0),
            Strategy("Adaptive-Merged", 0.02, 0.1, 2.0, 1.0, :sideways),
            Dict{String,Asset}(),
            Dict{String,Brain}(),
            Dict{String,Position}(),
            Dict{Symbol,Any}(:name => "Joseph"),
            ""
        )
    end

    try
        init_brain()
        log_system_event("Brain initialized")
    catch e
        log_system_event("Brain init warning: $e")
    end

    try
        start_browser_server(iggy)
    catch e
        log_system_event("Browser server error: $e")
    end

    try
        start_discovery(iggy)
    catch e
        log_system_event("Discovery loop start error: $e")
    end

    try
        start_vision(iggy)
    catch e
        log_system_event("Vision loop start error: $e")
    end

    try
        run_status_monitor(iggy)
    catch e
        log_system_event("Status monitor error: $e")
    end

    try
        @async begin
            cns_main_loop_runner(
                iggy.cns_capital,
                iggy.cns_strategy,
                iggy.cns_assets,
                iggy.cns_brains,
                iggy.cns_positions,
                iggy
            )
        end
    catch e
        log_system_event("CNS runner error: $e")
    end

    try
        for s in SYMBOLS
            Threads.@spawn begin
                try
                    log_system_event("Symbol thread started: $s")
                catch e
                    log_system_event("Symbol thread $s error: $e")
                end
            end
        end
    catch e
        log_system_event("Symbol threading error: $e")
    end

    run_repl(iggy)

    println("👋 IGGY shut down cleanly.")
    log_system_event("System shutdown")
end

# ──────────────────────────────────────────────────────────────────────────
# ENTRYPOINT
# ──────────────────────────────────────────────────────────────────────────

if PROGRAM_FILE == @__FILE__
    try
        run_executive_merged()
    catch e
        println("💥 CRITICAL SYSTEM ERROR: $e")
        log_system_event("CRITICAL SYSTEM ERROR: $e")
        rethrow(e)
    end
end