# iggy_python_bridge.jl
# Drop this into your IIGY-v1 repo.
# Connects iggy_executive.jl to the Python assistant over a TCP socket.
# The Python side (iggy_assistant.py) listens on port 9999.

module IggyPythonBridge

using Sockets, JSON

const PYTHON_HOST = "127.0.0.1"
const PYTHON_PORT = 9999
const RECONNECT_DELAY = 5  # seconds

# ── Send a message to IGGY's Python brain ─────────────────────────────────────
function send_to_iggy(msg::String)::String
    try
        sock = connect(PYTHON_HOST, PYTHON_PORT)
        write(sock, msg)
        response = String(readavailable(sock))
        close(sock)
        return response
    catch e
        return "Bridge unavailable: $e"
    end
end

# ── Push a trade event to IGGY so she can learn from it ───────────────────────
function notify_trade(symbol::String, side::String, price::Float64, pnl::Float64)
    msg = JSON.json(Dict(
        "type"   => "trade_event",
        "symbol" => symbol,
        "side"   => side,
        "price"  => price,
        "pnl"    => pnl,
        "ts"     => string(now()),
    ))
    send_to_iggy(msg)
end

# ── Ask IGGY for strategic input ──────────────────────────────────────────────
function ask_iggy(question::String)::String
    msg = JSON.json(Dict(
        "type"     => "query",
        "question" => question,
    ))
    return send_to_iggy(msg)
end

# ── Push status so IGGY can report it in chat ─────────────────────────────────
function push_status(capital::Float64, drawdown::Float64, active_positions::Int)
    msg = JSON.json(Dict(
        "type"             => "status",
        "capital"          => capital,
        "drawdown_pct"     => drawdown * 100,
        "active_positions" => active_positions,
        "ts"               => string(now()),
    ))
    send_to_iggy(msg)
end

end  # module IggyPythonBridge
