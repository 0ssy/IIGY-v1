using Dates, JSON, Printf

# Include core IGGY modules
include("iggy_persistence.jl")
include("iggy_ontology.jl")
include("iggy_inference_engine.jl")
include("iggy_graph_traversal.jl")
include("iggy_perception_parser.jl")
include("iggy_cns_core.jl") # The trading core
include("iggy_bridge.jl") # The interaction layer
include("iggy_discovery_loop.jl") # For world knowledge acquisition

# ─────────────────────────────────────────
# EXECUTIVE CORE
# ─────────────────────────────────────────
function main_loop()
    # Initialize IGGY's global state
    iggy_state = initialize_iggy_state()

    # Run initial knowledge discovery
    @async begin
        println("Starting Sovereign Discovery...")
        IggyDiscoveryLoop.run_sovereign_discovery_loop(iggy_state.kg, "domains_clean.csv")
    end

    # Load persisted state if available
    # iggy_state = IGGYPersistence.load_state() # Placeholder for actual persistence logic

    println("🚀 IGGY EXECUTIVE ACTIVE")

    # Start CNS in a separate asynchronous task
    cns_task = @async begin
        println("Starting CNS Core...")
        # The cns_main_loop_runner will manage the WebSocket connection and kline processing
        cns_main_loop_runner(iggy_state.cns_capital, iggy_state.cns_strategy, 
                             iggy_state.cns_assets, iggy_state.cns_brains, 
                             iggy_state.cns_positions)
    end

    # Main interaction loop (Perceive, Reason, Act)
    while true
        print("\nUser > ")
        user_input = readline()

        if lowercase(user_input) == "exit"
            println("IGGY > Goodbye!")
            # Optionally, cancel the CNS task and save state
            # Base.throwto(cns_task, InterruptException())
            # IGGYPersistence.save_state(iggy_state)
            break
        end

        # Process user input through the IGGY Bridge
        iggy_response = iggy_interact(iggy_state, user_input)
        println("IGGY > $iggy_response")

        # Allow CNS task to run in the background
        yield()
    end
end

# This function will encapsulate the CNS WebSocket logic and be called by the executive
function cns_main_loop_runner(capital::Capital, strat::Strategy, assets::Dict{String,Asset}, brains::Dict{String,Brain}, positions::Dict{String,Position})
    kline_channel = Channel(100)

    stream_names = [lowercase(s) * "@kline_" * KLINE_INTERVAL for s in SYMBOLS]
    websocket_url = WS_BASE_URL * "?streams=" * join(stream_names, "/")

    @async begin
        try
            HTTP.WebSockets.open(websocket_url) do ws
                println("CNS WebSocket connected to $websocket_url")
                for msg in ws
                    data = JSON.parse(String(msg))
                    if haskey(data, "data") && haskey(data["data"], "k")
                        k = data["data"]["k"]
                        if k["x"]; put!(kline_channel, k); end
                    end
                end
            end
        catch e; println("\nCNS WebSocket Error: $e"); end
    end

    while capital.dd < MAX_DD
        # This loop now primarily waits for kline data and processes it
        # The interaction loop in main_loop() handles user input concurrently
        if isready(kline_channel)
            cns_main_loop_step(capital, strat, assets, brains, positions, kline_channel)
            # Print CNS status after each kline update
            @printf("💰 %.2f | DD: %.2f%% | Active: %d\r", 
                capital.balance, capital.dd*100, length(positions))
        else
            yield() # Allow other tasks (like user interaction) to run
        end
    end
    println("\n🛑 CNS MAX DRAWDOWN REACHED")
end

main_loop()
