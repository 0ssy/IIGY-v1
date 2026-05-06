# ─────────────────────────────────────────
# IGGY EXECUTIVE v2
# ─────────────────────────────────────────
# Runs everything:
#   • CNS trading core   (background async)
#   • Sovereign discovery loop (background async)
#   • Conversation loop  → Python brain via socket
#
# Prerequisites:
#   1. python iggy_assistant.py --server   (in a separate terminal)
#   2. julia --threads auto iggy_executive.jl
# ─────────────────────────────────────────

using Dates, JSON, Printf

include("iggy_persistence.jl")
include("iggy_ontology.jl")
include("iggy_inference_engine.jl")
include("iggy_graph_traversal.jl")
include("iggy_perception_parser.jl")
include("iggy_cns_core.jl")          # trading engine
include("iggy_python_bridge.jl")     # ← Python brain socket client
include("iggy_discovery_loop.jl")

# ─────────────────────────────────────────
# MAIN LOOP
# ─────────────────────────────────────────

function main_loop()
    println("🚀 IGGY EXECUTIVE v2 starting…")

    # ── CNS state ────────────────────────
    capital, strategy, assets, brains, positions, kline_ch =
        initialize_iggy_state(balance = 1000.0)

    # ── Background: sovereign discovery ──
    @async begin
        println("🌐 Sovereign Discovery starting…")
        try
            IggyDiscoveryLoop.run_sovereign_discovery_loop(
                IggyOntology.KnowledgeGraph(), "domains_clean.csv")
        catch e
            println("Discovery loop error: $e")
        end
    end

    # ── Background: CNS trading ───────────
    @async begin
        println("📈 CNS Core starting…")
        try
            run_cns_v5()
        catch e
            println("CNS error: $e")
        end
    end

    # ── Wait a moment for things to spin up
    sleep(1)
    println("\n" * "─"^50)
    println("  IGGY is online.  Type to talk.  'exit' to quit.")
    println("─"^50 * "\n")

    # ── Conversation loop ─────────────────
    while true
        print("You > ")
        user_input = readline()
        isempty(strip(user_input)) && continue

        if lowercase(strip(user_input)) == "exit"
            println("IGGY > Goodbye.")
            break
        end

        # Build a short trading context string so IGGY knows what's happening
        pnl_summary = join(
            ["$s: $(round(total_pnl[s], digits=4))" for s in SYMBOLS], " | ")
        wins  = successful_trades[]
        losses = failed_trades[]
        ctx   = "Trading PnL [$pnl_summary] Wins:$wins Losses:$losses"

        # Ask the Python brain
        reply = IggyPythonBridge.ask_brain(user_input; context=ctx)
        println("IGGY > $reply\n")

        yield()  # let async tasks breathe
    end
end

main_loop()
