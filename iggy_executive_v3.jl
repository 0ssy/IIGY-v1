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
include("iggy_brain_merged.jl")       # LLM brain (iggy_think, iggy_learn, etc.)
include("iggy_discovery_loop.jl")     # World knowledge acquisition
include("iggy_vision.jl")             # Screen learning & perception

# ──────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────

const IGGY_VERSION = "4.5-Merged"
const LOG_FILE = "iggy_executive_merged.log"
const CHAT_PORT = 8765

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
    
    # Add brain status if available
    try
        show_brain_status()
    catch
        # Brain not initialized yet
    end
    
    println("="^60 * "\n")
end

# ──────────────────────────────────────────────────────────────────────────
# BROWSER CHAT SERVER
# Listens on http://localhost:CHAT_PORT so a browser page can talk to IGGY
# ──────────────────────────────────────────────────────────────────────────

function start_browser_server(iggy::IGGYState)
    @async begin
        try
            HTTP.serve("0.0.0.0", CHAT_PORT) do req
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
                        # Build trade context string
                        ctx = build_trade_context_string(iggy)
                        response = iggy_think(user_msg; trade_context=ctx)

                        return HTTP.Response(200,
                            ["Content-Type" => "application/json",
                             "Access-Control-Allow-Origin" => "*"],
                            body=JSON.json(Dict("response" => response))
                        )
                    end

                elseif req.method == "GET" && req.target == "/status"
                    stats = get_iggy_stats(iggy)
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
        # Capital metrics
        capital = iggy.cns_capital
        push!(lines, @sprintf("Balance: %.2f | DD: %.2f%%",
            capital.balance, capital.dd * 100))

        # Win rate
        wins = successful_trades[]
        total = wins + failed_trades[]
        wr = total == 0 ? 0.0 : wins / total
        push!(lines, @sprintf("Trades: %d (%.1f%% win)", total, 100 * wr))

        # Open positions
        if !isempty(open_pos)
            push!(lines, "Open: " * join(
                ["$(s): $(p.side) @ $(round(p.entry, digits=2))" for (s, p) in open_pos], ", "
            ))
        end

        # Per-symbol metrics
        for s in SYMBOLS
            try
                b = adaptive_bias(adapt_mem[s])
                push!(lines, @sprintf("  %s bias: %.2f | pnl: %.4f", s, b, total_pnl[s]))
            catch
                # Symbol not yet initialized
            end
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
    stream_names = [lowercase(s) * "@kline_" * KLINE_INTERVAL for s in SYMBOLS]
    websocket_url = WS_BASE_URL * "?streams=" * join(stream_names, "/")

    # WebSocket listener
    @async begin
        while true
            try
                HTTP.WebSockets.open(websocket_url) do ws
                    println("✅ CNS WebSocket connected → $websocket_url")
                    for msg in ws
                        data = JSON.parse(String(msg))
                        if haskey(data, "data") && haskey(data["data"], "k")
                            k = data["data"]["k"]
                            if k["x"]
                                put!(kline_channel, k)
                            end
                        end
                    end
                end
            catch e
                println("⚠️  CNS WebSocket dropped: $(typeof(e)) — reconnecting in 3s...")
                sleep(3)
            end
        end
    end

    # Trading loop
    while capital.dd < MAX_DD
        if isready(kline_channel)
            k = take!(kline_channel)
            sym = uppercase(get(k, "s", ""))

            # Run CNS trading step
            try
                cns_main_loop_step(capital, strat, assets, brains, positions, kline_channel)
            catch e
                log_system_event("CNS step error: $e")
            end

            @printf("💰 %.2f | DD: %.2f%% | Open: %d\r",
                capital.balance, capital.dd * 100, length(positions))
        else
            yield()
            sleep(0.05)
        end
    end

    println("\n🛑 CNS MAX DRAWDOWN REACHED — trading halted")
    log_system_event("CNS halted: max drawdown reached")
end

# ──────────────────────────────────────────────────────────────────────────
# STATUS MONITOR (thread 5)
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
# VISION LOOP (thread 4)
# ──────────────────────────────────────────────────────────────────────────

function start_vision(iggy::IGGYState)
    @async begin
        try
            run_vision_loop()
        catch e
            if isa(e, UndefVarError) && e.var == :run_vision_loop
                println("ℹ️  iggy_vision.jl not loaded — screen learning disabled")
            else
                println("⚠️  Vision loop error: $e")
            end
        end
    end
end

# ──────────────────────────────────────────────────────────────────────────
# DISCOVERY LOOP (async background)
# ──────────────────────────────────────────────────────────────────────────

function start_discovery(iggy::IGGYState)
    @async begin
        println("🌍 Starting Sovereign Discovery Loop...")
        try
            # Attempt to use knowledge graph if available
            if hasfield(typeof(iggy), :kg)
                # run_sovereign_discovery_loop(iggy.kg, "domains_clean.csv")
            end
        catch e
            println("⚠️  Discovery loop error: $e")
        end
    end
end

# ──────────────────────────────────────────────────────────────────────────
# ASSISTANT TASKS (v4.0 feature)
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
# Runs on main thread — handles typed commands
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
            isa(e, EOFError) ? "exit" : ""
        end

        input = strip(raw)
        isempty(input) && continue

        # ── Built-in commands ─────────────────────────────────────────────
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

        # ── LLM conversation ──────────────────────────────────────────────
        ctx = build_trade_context_string(iggy)
        response = iggy_think(input; trade_context=ctx)
        println("IGGY > $response\n")

        yield()
    end
end

# ──────────────────────────────────────────────────────────────────────────
# MAIN INITIALIZATION & RUNNER
# ──────────────────────────────────────────────────────────────────────────

"""
    run_executive_merged()

Main entry point. Initializes all systems and runs the REPL.
"""
function run_executive_merged()
    log_system_event("IGGY v$IGGY_VERSION initializing...")

    # 1. Initialize full IGGY state (bridge + CNS + ontology)
    try
        iggy = initialize_iggy_state()
        log_system_event("State initialized")
    catch e
        log_system_event("State initialization warning: $e (continuing with minimal state)")
        iggy = (
            cns_capital = Capital(1000.0, 0.0, 1000.0, 0.0, 1000.0),
            cns_strategy = Strategy("Merged", 0.02),
            cns_assets = Dict(),
            cns_brains = Dict(),
            cns_positions = Dict()
        )
    end

    # 2. Brain initialization
    try
        init_brain()
        log_system_event("Brain initialized")
    catch e
        log_system_event("Brain init warning: $e")
    end

    # 3. Browser chat server
    try
        start_browser_server(iggy)
    catch e
        log_system_event("Browser server error: $e")
    end

    # 4. Discovery loop (background)
    try
        start_discovery(iggy)
    catch e
        log_system_event("Discovery loop start error: $e")
    end

    # 5. Vision / screen learning (background)
    try
        start_vision(iggy)
    catch e
        log_system_event("Vision loop start error: $e")
    end

    # 6. Status monitor (background, prints every 60s)
    try
        run_status_monitor(iggy)
    catch e
        log_system_event("Status monitor error: $e")
    end

    # 7. CNS trading engine (background — WebSocket + trading loop)
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

    # 8. Per-symbol threads for tick-level TP/SL
    try
        for s in SYMBOLS
            Threads.@spawn begin
                try
                    log_system_event("Symbol thread started: $s")
                    # connect(s) would go here if implemented
                catch e
                    log_system_event("Symbol thread $s error: $e")
                end
            end
        end
    catch e
        log_system_event("Symbol threading error: $e")
    end

    # 9. REPL — blocks main thread
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
