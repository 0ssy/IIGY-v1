using HTTP, JSON, Sockets

# ─────────────────────────────────────────────────────────────────────────────
# iggy_chat_server.jl
#
# Provides:
#   CHAT_IN          :: Channel{String}   — incoming user messages from browser
#   CHAT_OUT         :: Channel{String}   — IGGY replies destined for browser
#   start_chat_server(; port)             — launch HTTP server (non-blocking)
#   push_chat_stats(; btc, eth, sol, wins, losses, winrate)
#                                         — update the live header bar
# ─────────────────────────────────────────────────────────────────────────────

# ── Shared channels (executive reads/writes these) ────────────────────────────
const CHAT_IN  = Channel{String}(64)
const CHAT_OUT = Channel{String}(64)

# ── Live stats (updated by CNS runner, read by /stats endpoint) ──────────────
const _STATS_LOCK = ReentrantLock()
const _stats = Dict{String,Any}(
    "btc"     => "—",
    "eth"     => "—",
    "sol"     => "—",
    "wins"    => 0,
    "losses"  => 0,
    "winrate" => 0.0,
)

function push_chat_stats(; btc="", eth="", sol="",
                           wins=0, losses=0, winrate=0.0)
    lock(_STATS_LOCK) do
        if !isempty(btc);  _stats["btc"]     = btc;     end
        if !isempty(eth);  _stats["eth"]     = eth;     end
        if !isempty(sol);  _stats["sol"]     = sol;     end
        _stats["wins"]    = wins
        _stats["losses"]  = losses
        _stats["winrate"] = winrate
    end
end

# ─────────────────────────────────────────
# HTML UI
# ─────────────────────────────────────────
const CHAT_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>IGGY Chat</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'Segoe UI', sans-serif; background: #0d0d0d; color: #e0e0e0;
         display: flex; flex-direction: column; height: 100vh; }

  /* ── Header bar ── */
  #header { background: #111; padding: 8px 16px; display: flex;
            align-items: center; gap: 20px; border-bottom: 1px solid #222;
            font-size: 0.82em; flex-wrap: wrap; }
  #header .logo { font-weight: 700; font-size: 1.1em; color: #00d4ff;
                  letter-spacing: 2px; margin-right: 12px; }
  .stat { color: #aaa; }
  .stat span { color: #00d4ff; font-weight: 600; }
  .win  { color: #00e676 !important; }
  .loss { color: #ff5252 !important; }

  /* ── Messages ── */
  #messages { flex: 1; overflow-y: auto; padding: 16px;
              display: flex; flex-direction: column; gap: 10px; }
  .bubble { max-width: 72%; padding: 10px 14px; border-radius: 14px;
            line-height: 1.5; word-break: break-word; }
  .user  { background: #1e3a5f; align-self: flex-end; border-bottom-right-radius: 4px; }
  .iggy  { background: #1a1a2e; border: 1px solid #222;
            align-self: flex-start; border-bottom-left-radius: 4px; }
  .iggy .name { font-size: 0.75em; color: #00d4ff; margin-bottom: 4px; font-weight: 700; }

  /* ── Input row ── */
  #inputrow { display: flex; gap: 8px; padding: 12px 16px;
              border-top: 1px solid #222; background: #111; }
  #msgbox { flex: 1; background: #1a1a1a; border: 1px solid #333;
            border-radius: 8px; padding: 10px 14px; color: #e0e0e0;
            font-size: 0.95em; outline: none; resize: none; }
  #msgbox:focus { border-color: #00d4ff; }
  #sendbtn { background: #00d4ff; color: #000; border: none;
             border-radius: 8px; padding: 0 22px; font-weight: 700;
             cursor: pointer; font-size: 0.95em; }
  #sendbtn:hover { background: #00b8d9; }
</style>
</head>
<body>

<div id="header">
  <span class="logo">IGGY</span>
  <span class="stat">BTC <span id="h-btc">—</span></span>
  <span class="stat">ETH <span id="h-eth">—</span></span>
  <span class="stat">SOL <span id="h-sol">—</span></span>
  <span class="stat">W <span id="h-wins" class="win">0</span>
                     L <span id="h-losses" class="loss">0</span>
                     WR <span id="h-wr">0.0%</span></span>
</div>

<div id="messages">
  <div class="bubble iggy">
    <div class="name">IGGY</div>
    Hello! I'm online and monitoring the markets. How can I help?
  </div>
</div>

<div id="inputrow">
  <textarea id="msgbox" rows="1" placeholder="Message IGGY…"></textarea>
  <button id="sendbtn">Send</button>
</div>

<script>
const messages = document.getElementById('messages');
const msgbox   = document.getElementById('msgbox');
const sendbtn  = document.getElementById('sendbtn');

function addBubble(text, role) {
  const d = document.createElement('div');
  d.className = 'bubble ' + role;
  if (role === 'iggy') {
    const n = document.createElement('div'); n.className = 'name'; n.textContent = 'IGGY';
    d.appendChild(n);
  }
  const t = document.createElement('span'); t.textContent = text;
  d.appendChild(t);
  messages.appendChild(d);
  messages.scrollTop = messages.scrollHeight;
}

async function sendMessage() {
  const text = msgbox.value.trim();
  if (!text) return;
  msgbox.value = '';
  addBubble(text, 'user');
  try {
    const r = await fetch('/chat', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({message: text})
    });
    const d = await r.json();
    addBubble(d.reply || '…', 'iggy');
  } catch {
    addBubble('[connection error]', 'iggy');
  }
}

sendbtn.addEventListener('click', sendMessage);
msgbox.addEventListener('keydown', e => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
});

// Poll live stats every 2 s
async function pollStats() {
  try {
    const r = await fetch('/stats'); const d = await r.json();
    if (d.btc)  document.getElementById('h-btc').textContent     = d.btc;
    if (d.eth)  document.getElementById('h-eth').textContent     = d.eth;
    if (d.sol)  document.getElementById('h-sol').textContent     = d.sol;
    document.getElementById('h-wins').textContent    = d.wins    ?? 0;
    document.getElementById('h-losses').textContent  = d.losses  ?? 0;
    document.getElementById('h-wr').textContent      = (d.winrate ?? 0).toFixed(1) + '%';
  } catch {}
  setTimeout(pollStats, 2000);
}
pollStats();
</script>
</body>
</html>
"""

# ─────────────────────────────────────────
# HTTP REQUEST ROUTER
# ─────────────────────────────────────────
function handle_request(req::HTTP.Request) :: HTTP.Response
    path = req.target

    # ── Serve the SPA ─────────────────────────────────────────────
    if path == "/" || path == "/index.html"
        return HTTP.Response(200,
            ["Content-Type" => "text/html; charset=utf-8"],
            body = CHAT_HTML)
    end

    # ── Live stats (polled every 2 s by browser) ──────────────────
    if path == "/stats"
        stats_copy = lock(_STATS_LOCK) do; copy(_stats); end
        return HTTP.Response(200,
            ["Content-Type" => "application/json"],
            body = JSON.json(stats_copy))
    end

    # ── Chat endpoint ─────────────────────────────────────────────
    if path == "/chat" && req.method == "POST"
        try
            body = JSON.parse(String(req.body))
            msg  = get(body, "message", "")
            if isempty(msg)
                return HTTP.Response(400,
                    ["Content-Type" => "application/json"],
                    body = JSON.json(Dict("error" => "empty message")))
            end

            # Send to executive event loop and wait for reply
            put!(CHAT_IN, msg)
            reply = ""
            timeout = time() + 60.0   # 60 s hard cap
            while time() < timeout
                if isready(CHAT_OUT)
                    reply = take!(CHAT_OUT)
                    break
                end
                sleep(0.02)
            end
            isempty(reply) && (reply = "[IGGY is thinking… try again in a moment]")

            return HTTP.Response(200,
                ["Content-Type" => "application/json"],
                body = JSON.json(Dict("reply" => reply)))
        catch e
            return HTTP.Response(500,
                ["Content-Type" => "application/json"],
                body = JSON.json(Dict("error" => string(e))))
        end
    end

    # ── 404 ───────────────────────────────────────────────────────
    return HTTP.Response(404, body = "Not found")
end

# ─────────────────────────────────────────
# SERVER ENTRY POINT
# ─────────────────────────────────────────

"""
    start_chat_server(; port=7171)

Launch the HTTP chat server in a background task.
Returns immediately; the server runs on its own async task.
"""
function start_chat_server(; port::Int = 7171)
    @async begin
        try
            println("💬 IGGY Chat UI  →  http://127.0.0.1:$port")
            HTTP.serve(handle_request, "127.0.0.1", port)
        catch e
            println("Chat server error: $e")
        end
    end
end
