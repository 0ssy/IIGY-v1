#
# iggy_python_bridge.jl
# ─────────────────────────────────────────
# Thin socket client — Julia asks, Python brain answers.
# Include this file in iggy_executive.jl.
# The Python side (iggy_assistant.py) must be running as a socket server.
#
# Protocol (newline-delimited JSON over TCP):
#   Julia → Python:  {"type":"chat","text":"...","context":"..."}\n
#   Python → Julia:  {"reply":"..."}\n
#
# Start Python server first:
#   python iggy_assistant.py --server
#

module IggyPythonBridge

using Sockets, JSON

const BRAIN_HOST = "127.0.0.1"
const BRAIN_PORT = 5050
const TIMEOUT_SEC = 30   # TinyLlama can be slow on first token

"""
    ask_brain(text; context="") -> String

Send `text` to the Python brain and return IGGY's reply.
Falls back to a local stub if the server isn't running.
"""
function ask_brain(text::String; context::String = "") :: String
    try
        sock = connect(BRAIN_HOST, BRAIN_PORT)
        payload = JSON.json(Dict("type" => "chat", "text" => text,
                                  "context" => context)) * "\n"
        write(sock, payload)

        # Read reply with timeout via a task
        reply_ref = Ref("")
        done      = Ref(false)
        @async begin
            try
                line = readline(sock)
                data = JSON.parse(line)
                reply_ref[] = get(data, "reply", "...")
            catch
                reply_ref[] = ""
            finally
                done[] = true
                close(sock)
            end
        end

        t0 = time()
        while !done[] && (time() - t0) < TIMEOUT_SEC
            sleep(0.1)
        end
        close(sock)

        reply = strip(reply_ref[])
        return isempty(reply) ? "[IGGY brain timeout — is iggy_assistant.py --server running?]" : reply

    catch e
        return "[IGGY brain offline — start: python iggy_assistant.py --server]"
    end
end

end  # module IggyPythonBridge
