module IggyPythonBridge

#
# iggy_python_bridge.jl
# ─────────────────────────────────────────────────────────────────────────────
# Thin socket client — Julia asks, Python brain answers.
#
# Protocol (newline-delimited JSON over TCP):
#   Julia  → Python :  {"type":"chat","text":"...","context":"..."}\n
#   Python → Julia  :  {"reply":"..."}\n
#
# Start the Python server first:
#   python iggy_assistant.py --server
# ─────────────────────────────────────────────────────────────────────────────

using Sockets, JSON

const BRAIN_HOST  = "127.0.0.1"
const BRAIN_PORT  = 5050
const TIMEOUT_SEC = 30   # seconds to wait for LLM reply (TinyLlama can be slow)

"""
    ask_brain(text; context="") -> String

Send `text` to the Python brain and return IGGY's reply.
Returns a descriptive fallback string if the server is unreachable or times out.
"""
function ask_brain(text::String; context::String = "") :: String
    try
        sock = connect(BRAIN_HOST, BRAIN_PORT)

        payload = JSON.json(Dict(
            "type"    => "chat",
            "text"    => text,
            "context" => context
        )) * "\n"
        write(sock, payload)

        # ── Read response with a hard timeout ────────────────────
        # The async task owns the socket and closes it when done.
        # On timeout we close the socket from outside, which unblocks
        # readline() inside the task.
        reply_ref = Ref{String}("")
        done_ref  = Ref{Bool}(false)

        @async begin
            try
                line          = readline(sock)   # blocks until \n or socket closes
                data          = JSON.parse(line)
                reply_ref[]   = get(data, "reply", "")
            catch
                reply_ref[]   = ""
            finally
                done_ref[]    = true
                close(sock)   # ← socket is closed exactly once, here
            end
        end

        t0 = time()
        while !done_ref[] && (time() - t0) < TIMEOUT_SEC
            sleep(0.05)
        end

        # If we timed out, closing the socket unblocks readline in the task
        if !done_ref[]
            try; close(sock); catch; end
        end

        reply = strip(reply_ref[])
        return isempty(reply) ?
            "[IGGY brain timeout — is iggy_assistant.py --server running?]" :
            reply

    catch e
        return "[IGGY brain offline — start: python iggy_assistant.py --server  ($e)]"
    end
end

end  # module IggyPythonBridge
