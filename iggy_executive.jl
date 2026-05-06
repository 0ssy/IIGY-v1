using Dates, JSON, Printf

# ── Same include order as the original repo (this order works) ────
include("iggy_persistence.jl")
include("iggy_ontology.jl")
include("iggy_inference_engine.jl")
include("iggy_graph_traversal.jl")
include("iggy_perception_parser.jl")
include("iggy_cns_core.jl")        # ← defines Capital, Strategy, Asset, Brain, Position
include("iggy_bridge.jl")          # ← defines iggy_interact / initialize_iggy_state
include("iggy_discovery_loop.jl")
include("iggy_chat_server.jl")     # ← browser UI + CHAT_IN / CHAT_OUT channels

# ─────────────────────────────────────────
# EXECUTIVE CORE
# ─────────────────────────────────────────
function main_loop()
    iggy_state = initialize_iggy_state()

    @async begin
        println("🌐 Sovereign Discovery starting…")
        try
            IggyDiscoveryLoop.run_sovereign_discovery_loop(iggy_state.kg, "domains_clean.csv")
        catch e
            println("Discovery loop error: $e")
        end
    end

    println("🚀 IGGY EXECUTIVE v2 starting…")

    # Start browser chat UI
    start_chat_server(port=7171)

    # Start CNS trading engine
    @async begin
        println("📈 CNS Core starting…")
        cns_main_loop_runner(iggy_state.cns_capital, iggy_state.cns_strategy,
                             iggy_state.cns_assets, iggy_state.cns_brains,
                             iggy_state.cns_positions)
    end

    println("\n──────────────────────────────────────────────────")
    println("  IGGY is online.")
    println("  💬 Chat in browser → http://localhost:7171")
    println("  Or type below.  'exit' to quit.")
    println("──────────────────────────────────────────────────\n")

    # ── FIX: terminal input in its own async task ─────────────────
    # readline() blocks — if it's inline it starves the CNS engine
    # AND the browser chat handler. Channel decouples it.
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
function cns_main_loop_runner(capital::Capital, strat::Strategy,
                               assets::Dict{String,Asset},
                               brains::Dict{String,Brain},
                               positions::Dict{String,Position})
    kline_channel = Channel(100)
    stream_names  = [lowercase(s) * "@kline_" * KLINE_INTERVAL for s in SYMBOLS]
    websocket_url = WS_BASE_URL * "?streams=" * join(stream_names, "/")

    @async begin
        try
            HTTP.WebSockets.open(websocket_url) do ws
                println("CNS WebSocket connected.")
                for msg in ws
                    data = JSON.parse(String(msg))
                    if haskey(data, "data") && haskey(data["data"], "k")
                        k = data["data"]["k"]
                        if k["x"]; put!(kline_channel, k); end
                    end
                end
            end
        catch e
            println("\nCNS WebSocket Error: $e")
        end
    end

    while capital.dd < MAX_DD
        if isready(kline_channel)
            cns_main_loop_step(capital, strat, assets, brains, positions, kline_channel)

            # ── Push live data to browser header bar ─────────────
            # successful_trades[] / failed_trades[] are the global
            # Ref counters defined in iggy_cns_core.jl — NOT fields
            # of Capital (Capital has no wins/losses fields).
            wins   = successful_trades[]
            losses = failed_trades[]
            wr     = (wins + losses) > 0 ? wins / (wins + losses) * 100.0 : 0.0

            btc = haskey(assets, "BTCUSDT") ? @sprintf("%.2f",  assets["BTCUSDT"].price) : ""
            eth = haskey(assets, "ETHUSDT") ? @sprintf("%.2f",  assets["ETHUSDT"].price) : ""
            sol = haskey(assets, "SOLUSDT") ? @sprintf("%.4f",  assets["SOLUSDT"].price) : ""

            push_chat_stats(btc=btc, eth=eth, sol=sol,
                            wins=wins, losses=losses, winrate=wr)
            # ─────────────────────────────────────────────────────

            @printf("💰 %.2f | DD: %.2f%% | Active: %d\r",
                capital.balance, capital.dd * 100, length(positions))
        else
            sleep(0.005)
        end
    end

    println("\n🛑 CNS MAX DRAWDOWN REACHED")
end

main_loop()
