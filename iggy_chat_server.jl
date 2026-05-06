# ─────────────────────────────────────────────────────────────────
#  iggy_chat_server.jl  –  Browser-based chat interface for IGGY
#  Runs on http://localhost:7171
# ─────────────────────────────────────────────────────────────────
# Requires:  HTTP.jl  (add with:  using Pkg; Pkg.add("HTTP"))
# ─────────────────────────────────────────────────────────────────

using HTTP, Dates, JSON

# ── Shared channels between the chat server and the executive ─────
const CHAT_IN  = Channel{String}(32)   # user message  → executive
const CHAT_OUT = Channel{String}(32)   # IGGY response → browser

# ── Embedded HTML / CSS / JS chat UI ─────────────────────────────
const CHAT_HTML = raw"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>IGGY</title>
<style>
  :root {
    --bg:      #0d0f14;
    --panel:   #13161e;
    --border:  #1e2535;
    --accent:  #00e5ff;
    --accent2: #7c3aed;
    --text:    #e2e8f0;
    --sub:     #64748b;
    --green:   #10b981;
    --red:     #ef4444;
    --user-bg: #1e2535;
    --iggy-bg: #111827;
    --radius:  12px;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background: var(--bg);
    color: var(--text);
    font-family: 'Segoe UI', system-ui, sans-serif;
    height: 100vh;
    display: flex;
    flex-direction: column;
  }

  /* ── Header ── */
  header {
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 14px 24px;
    background: var(--panel);
    border-bottom: 1px solid var(--border);
    flex-shrink: 0;
  }
  .avatar {
    width: 40px; height: 40px; border-radius: 50%;
    background: linear-gradient(135deg, var(--accent2), var(--accent));
    display: flex; align-items: center; justify-content: center;
    font-size: 18px; font-weight: 700; color: #fff;
    box-shadow: 0 0 12px rgba(0,229,255,.35);
  }
  .header-info h1 { font-size: 16px; font-weight: 700; letter-spacing: .5px; }
  .header-info p  { font-size: 12px; color: var(--sub); }
  .status-dot {
    width: 8px; height: 8px; border-radius: 50%;
    background: var(--green);
    box-shadow: 0 0 6px var(--green);
    margin-left: auto;
    animation: pulse 2s infinite;
  }
  @keyframes pulse {
    0%,100% { opacity: 1; } 50% { opacity: .4; }
  }

  /* ── Stats bar ── */
  #stats-bar {
    display: flex;
    gap: 24px;
    padding: 8px 24px;
    background: var(--panel);
    border-bottom: 1px solid var(--border);
    font-size: 12px;
    color: var(--sub);
    flex-shrink: 0;
    overflow-x: auto;
  }
  #stats-bar span { white-space: nowrap; }
  #stats-bar .val { color: var(--accent); font-weight: 600; }
  #stats-bar .win { color: var(--green); }
  #stats-bar .loss { color: var(--red); }

  /* ── Messages ── */
  #messages {
    flex: 1;
    overflow-y: auto;
    padding: 24px;
    display: flex;
    flex-direction: column;
    gap: 16px;
    scrollbar-width: thin;
    scrollbar-color: var(--border) transparent;
  }
  .msg {
    display: flex;
    gap: 10px;
    max-width: 75%;
    animation: fadein .2s ease;
  }
  @keyframes fadein { from { opacity:0; transform:translateY(6px); } to { opacity:1; transform:none; } }
  .msg.user  { align-self: flex-end; flex-direction: row-reverse; }
  .msg.iggy  { align-self: flex-start; }
  .msg .bubble {
    padding: 12px 16px;
    border-radius: var(--radius);
    font-size: 14px;
    line-height: 1.55;
    word-break: break-word;
  }
  .msg.user  .bubble { background: var(--accent2); color: #fff; border-bottom-right-radius: 3px; }
  .msg.iggy  .bubble { background: var(--iggy-bg); border: 1px solid var(--border); border-bottom-left-radius: 3px; }
  .msg .mini-avatar {
    width: 30px; height: 30px; border-radius: 50%; flex-shrink: 0;
    display: flex; align-items: center; justify-content: center;
    font-size: 13px; font-weight: 700;
  }
  .msg.iggy  .mini-avatar { background: linear-gradient(135deg,var(--accent2),var(--accent)); color:#fff; }
  .msg.user  .mini-avatar { background: var(--user-bg); color: var(--text); }
  .timestamp { font-size: 11px; color: var(--sub); margin-top: 4px; text-align: right; }
  .msg.iggy  .timestamp { text-align: left; }

  /* ── Typing indicator ── */
  #typing { display:none; align-self: flex-start; }
  #typing.show { display:flex; }
  #typing .bubble { display:flex; gap:5px; align-items:center; padding: 12px 16px; }
  .dot { width:7px; height:7px; border-radius:50%; background: var(--sub); animation: bounce .9s infinite; }
  .dot:nth-child(2) { animation-delay: .15s; }
  .dot:nth-child(3) { animation-delay: .3s; }
  @keyframes bounce { 0%,60%,100% { transform:translateY(0); } 30% { transform:translateY(-6px); } }

  /* ── Input ── */
  #input-row {
    padding: 16px 24px;
    background: var(--panel);
    border-top: 1px solid var(--border);
    display: flex;
    gap: 10px;
    flex-shrink: 0;
  }
  #user-input {
    flex: 1;
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 12px 16px;
    color: var(--text);
    font-size: 14px;
    outline: none;
    transition: border-color .2s;
  }
  #user-input:focus { border-color: var(--accent); }
  #user-input::placeholder { color: var(--sub); }
  #send-btn {
    background: linear-gradient(135deg, var(--accent2), var(--accent));
    border: none; border-radius: var(--radius);
    padding: 0 20px; color: #fff;
    font-size: 18px; cursor: pointer;
    transition: opacity .2s, transform .1s;
  }
  #send-btn:hover  { opacity: .85; }
  #send-btn:active { transform: scale(.96); }
  #send-btn:disabled { opacity: .4; cursor: default; }

  /* ── Scrollbar ── */
  #messages::-webkit-scrollbar { width: 6px; }
  #messages::-webkit-scrollbar-track { background: transparent; }
  #messages::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
</style>
</head>
<body>

<header>
  <div class="avatar">I</div>
  <div class="header-info">
    <h1>IGGY</h1>
    <p>Autonomous Trading Intelligence</p>
  </div>
  <div class="status-dot" id="status-dot" title="Online"></div>
</header>

<div id="stats-bar">
  <span>BTC <span class="val" id="s-btc">–</span></span>
  <span>ETH <span class="val" id="s-eth">–</span></span>
  <span>SOL <span class="val" id="s-sol">–</span></span>
  <span>Wins <span class="win" id="s-wins">0</span></span>
  <span>Losses <span class="loss" id="s-losses">0</span></span>
  <span>Win% <span class="val" id="s-wr">0.00%</span></span>
</div>

<div id="messages">
  <div class="msg iggy">
    <div class="mini-avatar">I</div>
    <div>
      <div class="bubble">Hey! I'm IGGY — your trading intelligence. I'm live on BTC, ETH, and SOL right now. Ask me about open positions, P&amp;L, market status, or just say hi 👋</div>
      <div class="timestamp">System</div>
    </div>
  </div>
</div>

<div class="msg iggy" id="typing">
  <div class="mini-avatar">I</div>
  <div class="bubble"><div class="dot"></div><div class="dot"></div><div class="dot"></div></div>
</div>

<div id="input-row">
  <input id="user-input" type="text" placeholder="Talk to IGGY…" autocomplete="off" />
  <button id="send-btn">➤</button>
</div>

<script>
  const msgs     = document.getElementById('messages');
  const input    = document.getElementById('user-input');
  const btn      = document.getElementById('send-btn');
  const typing   = document.getElementById('typing');

  // ── Poll for stats every 3 s ──────────────────────────────────
  async function pollStats() {
    try {
      const r = await fetch('/stats');
      if (!r.ok) return;
      const d = await r.json();
      if (d.btc)     document.getElementById('s-btc').textContent     = '$' + d.btc;
      if (d.eth)     document.getElementById('s-eth').textContent     = '$' + d.eth;
      if (d.sol)     document.getElementById('s-sol').textContent     = '$' + d.sol;
      document.getElementById('s-wins').textContent    = d.wins    ?? 0;
      document.getElementById('s-losses').textContent  = d.losses  ?? 0;
      document.getElementById('s-wr').textContent      = (d.winrate ?? 0).toFixed(2) + '%';
    } catch(_) {}
  }
  setInterval(pollStats, 3000);
  pollStats();

  // ── Add bubble ─────────────────────────────────────────────────
  function addMsg(who, text) {
    const wrap = document.createElement('div');
    wrap.className = 'msg ' + who;

    const av = document.createElement('div');
    av.className = 'mini-avatar';
    av.textContent = who === 'iggy' ? 'I' : 'Y';

    const inner = document.createElement('div');
    const bubble = document.createElement('div');
    bubble.className = 'bubble';
    bubble.textContent = text;

    const ts = document.createElement('div');
    ts.className = 'timestamp';
    ts.textContent = new Date().toLocaleTimeString();

    inner.appendChild(bubble);
    inner.appendChild(ts);
    wrap.appendChild(av);
    wrap.appendChild(inner);
    msgs.appendChild(wrap);
    msgs.scrollTop = msgs.scrollHeight;
  }

  // ── Send ───────────────────────────────────────────────────────
  async function send() {
    const text = input.value.trim();
    if (!text) return;
    input.value = '';
    btn.disabled = true;

    addMsg('user', text);

    // show typing
    msgs.appendChild(typing);
    typing.classList.add('show');
    msgs.scrollTop = msgs.scrollHeight;

    try {
      const r = await fetch('/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ message: text })
      });
      const d = await r.json();
      typing.classList.remove('show');
      addMsg('iggy', d.response ?? '…');
    } catch(e) {
      typing.classList.remove('show');
      addMsg('iggy', '⚠️ Connection error – is IGGY running?');
    }

    btn.disabled = false;
    input.focus();
  }

  btn.addEventListener('click', send);
  input.addEventListener('keydown', e => { if (e.key === 'Enter') send(); });
</script>
</body>
</html>
"""

# ── Shared live stats (updated by cns_core via push_chat_stats) ──
const _chat_stats = Ref(Dict{String,Any}(
    "btc" => "", "eth" => "", "sol" => "",
    "wins" => 0, "losses" => 0, "winrate" => 0.0
))

"""
    push_chat_stats(; btc="", eth="", sol="", wins=0, losses=0)

Call this from iggy_cns_core.jl (or anywhere) to update the stats
shown in the browser's header bar.
"""
function push_chat_stats(; btc="", eth="", sol="",
                           wins=0, losses=0, winrate=0.0)
    _chat_stats[] = Dict{String,Any}(
        "btc" => btc, "eth" => eth, "sol" => sol,
        "wins" => wins, "losses" => losses, "winrate" => winrate
    )
end

# ── HTTP request router ───────────────────────────────────────────
function chat_router(req::HTTP.Request)
    if req.method == "GET" && req.target == "/"
        return HTTP.Response(200,
            ["Content-Type" => "text/html; charset=utf-8"],
            body = CHAT_HTML)

    elseif req.method == "GET" && req.target == "/stats"
        return HTTP.Response(200,
            ["Content-Type" => "application/json"],
            body = JSON.json(_chat_stats[]))

    elseif req.method == "POST" && req.target == "/chat"
        try
            body   = JSON.parse(String(req.body))
            msg    = get(body, "message", "")::String
            put!(CHAT_IN, msg)                     # → executive loop
            # wait up to 10 s for IGGY's reply
            reply  = ""
            t0     = time()
            while time() - t0 < 10.0
                if isready(CHAT_OUT)
                    reply = take!(CHAT_OUT); break
                end
                sleep(0.05)
            end
            if reply == ""
                reply = "I'm thinking… the trading engine kept me busy. Ask again in a moment."
            end
            return HTTP.Response(200,
                ["Content-Type" => "application/json"],
                body = JSON.json(Dict("response" => reply)))
        catch e
            return HTTP.Response(500,
                ["Content-Type" => "application/json"],
                body = JSON.json(Dict("response" => "Internal error: $e")))
        end

    else
        return HTTP.Response(404, "Not found")
    end
end

# ── Start the server (non-blocking) ──────────────────────────────
function start_chat_server(; host="127.0.0.1", port=7171)
    @async begin
        println("💬 IGGY Chat UI  →  http://$(host):$(port)")
        HTTP.serve(chat_router, host, port)
    end
end
