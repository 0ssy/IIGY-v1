using Dates, JSON, Printf

# ── Include order matters — each file assumes the ones above it are loaded ──
include("iggy_persistence.jl")
include("iggy_ontology.jl")
include("iggy_inference_engine.jl")
include("iggy_graph_traversal.jl")
include("iggy_perception_parser.jl")
include("iggy_cns_core.jl")          # defines Capital, Strategy, Asset, Brain, Position
include("iggy_bridge.jl")            # defines iggy_interact / initialize_iggy_state
include("iggy_discovery_loop.jl")    # defines run_sovereign_discovery_loop (top-level)
include("iggy_chat_server.jl")       # defines start_chat_server / CHAT_IN / CHAT_OUT / push_chat_stats
include("iggy_python_bridge.jl")     # defines IggyPythonBridge.ask_brain

# ─────────────────────────────────────────
# EXECUTIVE CORE
# ─────────────────────────────────────────
function main_loop()
    iggy_state = initialize_iggy_state()

    # ── Sovereign knowledge discovery (background) ────────────────
    @async begin
        println("🌐 Sovereign Discovery starting…")
        try
            # NOTE: call is top-level — there is NO IggyDiscoveryLoop module
            run_sovereign_discovery_loop(iggy_state.kg, "domains_clean.csv")
        catch e
            println("Discovery loop error: $e")
        end
    end

    println("🚀 IGGY EXECUTIVE v2 starting…")
    println("──────────────────────────────────────────────────")
    println("  IGGY is online.")
    println("  💬 Chat in browser → http://localhost:7171")
    println("  Or type below.  'exit' to quit.")
    println("──────────────────────────────────────────────────\n")

    # ── Browser chat UI ───────────────────────────────────────────
    start_chat_server(port=7171)

    # ── CNS trading engine (background) ──────────────────────────
    @async begin
        println("📈 CNS Core starting…")
        cns_main_loop_runner(
            iggy_state.cns_capital,
            iggy_state.cns_strategy,
            iggy_state.cns_assets,
            iggy_state.cns_brains,
            iggy_state.cns_positions
        )
    end

    # ── Terminal input in its own async task ──────────────────────
    # readline() blocks the calling thread; using a channel decouples it
    # from the CNS engine and browser chat handler.
    terminal_ch = Channel{String}(16)
    @async begin
        while true
            print("You > ")
            line = readline()
            put!(terminal_ch, line)
        end
    end

    # ── Non-blocking event loop ───────────────────────────────────
    while true
        # 1. Handle browser chat messages
        while isready(CHAT_IN)
            msg      = take!(CHAT_IN)
            response = iggy_interact(iggy_state, msg)
            put!(CHAT_OUT, response)
        end

        # 2. Handle terminal messages
        while isready(terminal_ch)
            user_input = take!(terminal_ch)
            if lowercase(strip(user_input)) == "exit"
                println("IGGY > Goodbye!")
                return
            end
            if !isempty(strip(user_input))
                iggy_response = iggy_interact(iggy_state, user_input)
                println("\nIGGY > $iggy_response\n")
            end
        end

        # 3. Yield CPU to CNS + HTTP tasks
        sleep(0.01)
    end
end

# ─────────────────────────────────────────
# CNS RUNNER
# ─────────────────────────────────────────
function cns_main_loop_runner(
        capital   :: Capital,
        strat     :: Strategy,
        assets    :: Dict{String,Asset},
        brains    :: Dict{String,Brain},
        positions :: Dict{String,Position})

    kline_channel = Channel(100)
    stream_names  = [lowercase(s) * "@kline_" * KLINE_INTERVAL for s in SYMBOLS]
    websocket_url = WS_BASE_URL * "?streams=" * join(stream_names, "/")

    # ── WebSocket feed (background) ───────────────────────────────
    @async begin
        try
            HTTP.WebSockets.open(websocket_url) do ws
                println("CNS WebSocket connected to $websocket_url")
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
            println("\nCNS WebSocket Error: $e")
        end
    end

    # ── Processing loop ───────────────────────────────────────────
    while capital.dd < MAX_DD
        if isready(kline_channel)
            cns_main_loop_step(capital, strat, assets, brains, positions, kline_channel)

            # Push live stats to browser header bar.
            # successful_trades[] / failed_trades[] are global Ref counters
            # defined in iggy_cns_core.jl — they are NOT fields of Capital.
            wins   = successful_trades[]
            losses = failed_trades[]
            wr     = (wins + losses) > 0 ? wins / (wins + losses) * 100.0 : 0.0

            btc = haskey(assets, "BTCUSDT") ? @sprintf("%.2f",  assets["BTCUSDT"].price) : "—"
            eth = haskey(assets, "ETHUSDT") ? @sprintf("%.2f",  assets["ETHUSDT"].price) : "—"
            sol = haskey(assets, "SOLUSDT") ? @sprintf("%.4f",  assets["SOLUSDT"].price) : "—"

            push_chat_stats(btc=btc, eth=eth, sol=sol,
                            wins=wins, losses=losses, winrate=wr)

            @printf("💰 %.2f | DD: %.2f%% | Active: %d\r",
                capital.balance, capital.dd * 100, length(positions))
        else
            sleep(0.005)
        end
    end

    println("\n🛑 CNS MAX DRAWDOWN REACHED")
end

main_loop()
