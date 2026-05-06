# ==============================================================================
# IGGY EXECUTIVE v3.0 — SOVEREIGN COMMAND CORE
# Merges: iggy_executive.jl (original) + iggy_executive_v3 (vision, threads, LLM)
#
# Run: julia --threads 8 iggy_executive_v3.jl
#
# Thread map:
#   Thread 1-3  → CNS trading (one per symbol via @spawn)
#   Thread 4    → Vision loop (screen learning, file watcher)
#   Thread 5    → Status monitor
#   Main thread → Conversation REPL + browser chat server
#
# Commands (type in REPL):
#   exit          — shut down
#   insights      — show learned trading rules
#   status        — print current CNS status
#   read <path>   — teach IGGY a file
#   url <link>    — teach IGGY a webpage
# ==============================================================================

using Dates, JSON, Printf, HTTP

# ── Include order matters ─────────────────────────────────────────────────────
include("iggy_persistence.jl")
include("iggy_ontology.jl")
include("iggy_inference_engine.jl")
include("iggy_graph_traversal.jl")
include("iggy_perception_parser.jl")
include("iggy_cns_core.jl")       # Trading engine (defines Capital, Strategy, Asset, etc.)
include("iggy_bridge.jl")         # iggy_interact + IGGYState + initialize_iggy_state
include("iggy_brain.jl")          # LLM brain (iggy_think, iggy_analyze_trade, etc.)
include("iggy_discovery_loop.jl") # World knowledge acquisition
include("iggy_vision.jl")         # Screen learning (new file — add to repo separately)

# ─────────────────────────────────────────
# BROWSER CHAT SERVER
# Listens on http://localhost:8765 so a browser page can talk to IGGY
# ─────────────────────────────────────────

const CHAT_PORT  = 8765
const CHAT_MSGS  = Channel{String}(50)   # incoming from browser
const CHAT_RESPS = Channel{String}(50)   # outgoing to browser

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
                    body     = JSON.parse(String(req.body))
                    user_msg = get(body, "message", "")

                    if !isempty(user_msg)
                        # Build trade context string
                        ctx = build_trade_context_string(iggy)
                        response = iggy_think(user_msg; trade_context=ctx)

                        return HTTP.Response(200,
                            ["Content-Type"                => "application/json",
                             "Access-Control-Allow-Origin" => "*"],
                            body=JSON.json(Dict("response" => response))
                        )
                    end

                elseif req.method == "GET" && req.target == "/status"
                    stats = get_iggy_stats(iggy)
                    return HTTP.Response(200,
                        ["Content-Type"                => "application/json",
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

# ─────────────────────────────────────────
# STATUS HELPERS
# ─────────────────────────────────────────

function build_trade_context_string(iggy::IGGYState) :: String
    lines = String[]
    push!(lines, @sprintf("Balance: %.2f | DD: %.2f%%",
        iggy.cns_capital.balance, iggy.cns_capital.dd * 100))

    wins  = successful_trades[]
    total = wins + failed_trades[]
    wr    = total > 0 ? 100.0 * wins / total : 0.0
    push!(lines, @sprintf("Trades: %d wins / %d total | Win rate: %.1f%%", wins, total, wr))

    if !isempty(open_pos)
        push!(lines, "Open positions: " * join(
            ["$(s): $(p.side) @ $(round(p.entry, digits=2))" for (s, p) in open_pos], ", "
        ))
    end

    for s in SYMBOLS
        b = adaptive_bias(adapt_mem[s])
        push!(lines, @sprintf("  %s bias: %.2f | pnl: %.4f", s, b, total_pnl[s]))
    end

    return join(lines, "\n")
end

function get_iggy_stats(iggy::IGGYState) :: Dict
    wins  = successful_trades[]
    total = wins + failed_trades[]
    return Dict(
        "balance"    => iggy.cns_capital.balance,
        "drawdown"   => round(iggy.cns_capital.dd * 100, digits=2),
        "wins"       => wins,
        "losses"     => failed_trades[],
        "win_rate"   => total > 0 ? round(100.0 * wins / total, digits=1) : 0.0,
        "open_pos"   => length(open_pos),
        "insights"   => length(IGGY_INSIGHTS),
        "timestamp"  => string(now())
    )
end

function push_chat_stats(iggy::IGGYState)
    # Periodic status print (replaces old push_chat_stats in v1)
    stats = get_iggy_stats(iggy)
    @printf("📊 [%s] Balance:%.2f | DD:%.1f%% | Wins:%d/%d | Open:%d | Insights:%d\n",
        Dates.format(now(), "HH:MM:SS"),
        stats["balance"], stats["drawdown"],
        stats["wins"], stats["wins"] + stats["losses"],
        stats["open_pos"], stats["insights"])
end

# ─────────────────────────────────────────
# CNS WEBSOCKET RUNNER (from iggy_executive.jl)
# Kept intact — runs the full multi-symbol WebSocket stream
# ─────────────────────────────────────────

function cns_main_loop_runner(capital::Capital, strat::Strategy,
                               assets::Dict{String,Asset},
                               brains::Dict{String,Brain},
                               positions::Dict{String,Position},
                               iggy::IGGYState)
    kline_channel = Channel(100)
    stream_names  = [lowercase(s) * "@kline_" * KLINE_INTERVAL for s in SYMBOLS]
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

            # Run standard CNS step
            cns_main_loop_step(capital, strat, assets, brains, positions, kline_channel)

            @printf("💰 %.2f | DD: %.2f%% | Open: %d\r",
                capital.balance, capital.dd * 100, length(positions))
        else
            yield()
            sleep(0.05)
        end
    end

    println("\n🛑 CNS MAX DRAWDOWN REACHED — trading halted")
end

# ─────────────────────────────────────────
# STATUS MONITOR (thread 5)
# ─────────────────────────────────────────

function run_status_monitor(iggy::IGGYState)
    @async begin
        while true
            sleep(60)
            push_chat_stats(iggy)
        end
    end
end

# ─────────────────────────────────────────
# VISION LOOP (thread 4)
# Calls iggy_vision.jl's run_vision_loop if available
# ─────────────────────────────────────────

function start_vision(iggy::IGGYState)
    @async begin
        try
            # iggy_vision.jl must export run_vision_loop()
            # It screenshots every 30s, sends to vision LLM, calls iggy_process_vision()
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

# ─────────────────────────────────────────
# DISCOVERY LOOP (async background)
# ─────────────────────────────────────────

function start_discovery(iggy::IGGYState)
    @async begin
        println("🌍 Starting Sovereign Discovery Loop...")
        try
            IggyDiscoveryLoop.run_sovereign_discovery_loop(iggy.kg, "domains_clean.csv")
        catch e
            println("⚠️  Discovery loop error: $e")
        end
    end
end

# ─────────────────────────────────────────
# CONVERSATION REPL
# Runs on main thread — handles typed commands
# ─────────────────────────────────────────

function run_repl(iggy::IGGYState)
    println("\n" * "="^60)
    println("  IGGY v3.0 — Type to talk. Commands: exit | insights | status")
    println("  'read <path>' to learn a file | 'url <link>' to learn a page")
    println("="^60 * "\n")

    while true
        print("You > ")
        raw = readline()
        input = strip(raw)
        isempty(input) && continue

        # ── Built-in commands ──────────────────────────────────────────────
        if lowercase(input) == "exit"
            println("IGGY > Goodbye. Saving state...")
            save_runtime_state!()
            break

        elseif lowercase(input) == "insights"
            show_insights()
            continue

        elseif lowercase(input) == "status"
            println(build_trade_context_string(iggy))
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
        end

        # ── LLM conversation ───────────────────────────────────────────────
        ctx = build_trade_context_string(iggy)
        response = iggy_think(input; trade_context=ctx)
        println("IGGY > $response\n")

        yield()
    end
end

# ─────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────

function main()
    println("🚀 IGGY EXECUTIVE v3.0 — Booting...")

    # 1. Initialize full IGGY state (bridge + CNS + ontology)
    iggy = initialize_iggy_state()

    # 2. Browser chat server
    start_browser_server(iggy)

    # 3. Discovery loop (background)
    start_discovery(iggy)

    # 4. Vision / screen learning (background)
    start_vision(iggy)

    # 5. Status monitor (background, prints every 60s)
    run_status_monitor(iggy)

    # 6. CNS trading engine (background — WebSocket + trading loop)
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

    # Also run the simpler per-symbol connect() loops from cns_core for tick-level TP/SL
    for s in SYMBOLS
        Threads.@spawn begin
            try
                connect(s)
            catch e
                println("⚠️  Symbol thread $s: $e")
            end
        end
    end

    # 7. REPL — blocks main thread
    run_repl(iggy)

    println("👋 IGGY shut down cleanly.")
end

main()