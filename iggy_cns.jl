# ==============================================================================
# PROJECT IGGY — CENTRAL NERVOUS SYSTEM v2.0
# ==============================================================================
# The unified hub. Runs everything simultaneously:
#   - Discovery loop (Google API → Vault)
#   - Trading engine (Stratosphere)
#   - Vault queries (knowledge informs trading)
#   - Telegram reports
#
# RUN: julia iggy_cns.jl
# ==============================================================================

using HTTP, JSON, SHA, Dates, Statistics, LinearAlgebra, Random, Printf, CSV, DataFrames

# ── LOAD SECRETS ──────────────────────────────────────────────────────────────
function load_env(path=joinpath(@__DIR__,".env"))
    env = Dict{String,String}()
    isfile(path) || error("Missing .env")
    for line in readlines(path)
        line = strip(line)
        isempty(line) && continue
        startswith(line,"#") && continue
        parts = split(line,"=";limit=2)
        length(parts)==2 && (env[strip(parts[1])]=strip(parts[2]))
    end
    return env
end

const ENV          = load_env()
const BINANCE_KEY  = get(ENV,"BINANCE_KEY","")
const BINANCE_SEC  = get(ENV,"BINANCE_SECRET","")
const TG_TOKEN     = get(ENV,"TELEGRAM_TOKEN","")
const TG_CHAT      = get(ENV,"TELEGRAM_CHAT_ID","")
const BASE_URL     = get(ENV,"BASE_URL","https://testnet.binance.vision")
const GOOGLE_KEY   = get(ENV,"GOOGLE_API_KEY","")
const GOOGLE_CX    = get(ENV,"GOOGLE_CX","")

# ── PATHS ─────────────────────────────────────────────────────────────────────
const IGGY_DIR     = @__DIR__
const KNOWLEDGE_CSV= joinpath(IGGY_DIR,"iggy_global_knowledge.csv")
const VAULT_FILE   = joinpath(IGGY_DIR,"iggy_vault_data.json")
const LOG_FILE     = joinpath(IGGY_DIR,"iggy_final_ledger.csv")
const CNS_LOG      = joinpath(IGGY_DIR,"iggy_cns_log.txt")

# ── CONFIG ────────────────────────────────────────────────────────────────────
const HIDDEN_DIM    = 64
const Z_CHUNK       = 8
const POPULATION    = 25
const THRESHOLD     = 0.3f0
const TARGET_TRADES = 50
const MIN_MOVE      = 0.0002   # 0.02% minimum price move to trade

# ── LOGGING ───────────────────────────────────────────────────────────────────
const LOG_LOCK = ReentrantLock()

function clog(msg::String; level="INFO")
    ts   = Dates.format(now(),"yyyy-mm-dd HH:MM:SS")
    line = "[$ts][$level] $msg"
    println(line)
    lock(LOG_LOCK) do
        open(CNS_LOG,"a") do f; println(f,line); end
    end
end

# ── TELEGRAM ──────────────────────────────────────────────────────────────────
function tg(msg::String)
    isempty(TG_TOKEN) && return
    try
        url  = "https://api.telegram.org/bot$TG_TOKEN/sendMessage"
        body = JSON.json(Dict("chat_id"=>TG_CHAT,"text"=>"IGGY: $msg"))
        HTTP.post(url,["Content-Type"=>"application/json"],body)
    catch; end
end

# ==============================================================================
# MODULE 1: IGGY VAULT — Vector Knowledge Store
# ==============================================================================
mutable struct VaultNode
    domain::String
    focus::String
    content::String
    vector::Vector{Float32}
    priority::String
    timestamp::String
end

const VAULT      = VaultNode[]
const VAULT_LOCK = ReentrantLock()

function encode_text(text::String)::Vector{Float32}
    v = zeros(Float32,64)
    h = sha256(lowercase(text[1:min(500,lastindex(text))]))
    for (i,b) in enumerate(h)
        v[mod1(i,64)] += Int(b) > 127 ? 1.0f0 : -1.0f0
    end
    n = norm(v); return n > 0 ? v./n : v
end

function vault_store!(domain::String, focus::String,
                      content::String, priority::String="High")
    node = VaultNode(domain, focus, content,
                     encode_text("$domain $focus $content"),
                     priority, string(now()))
    lock(VAULT_LOCK) do
        push!(VAULT, node)
        # Keep vault size manageable on i5
        length(VAULT) > 2000 && deleteat!(VAULT, 1)
    end
end

function vault_query(query::String; k::Int=3)::Vector{String}
    isempty(VAULT) && return String[]
    qv     = encode_text(query)
    scored = lock(VAULT_LOCK) do
        [(sum(qv.*n.vector)/(norm(qv)*norm(n.vector)+1e-8), n) for n in VAULT]
    end
    sort!(scored; by=x->x[1], rev=true)
    return [n.content[1:min(200,lastindex(n.content))]
            for (_,n) in scored[1:min(k,length(scored))]]
end

function save_vault()
    lock(VAULT_LOCK) do
        data = [Dict("domain"=>n.domain,"focus"=>n.focus,
                     "content"=>n.content,"priority"=>n.priority,
                     "timestamp"=>n.timestamp) for n in VAULT]
        open(VAULT_FILE,"w") do f; JSON.print(f,data); end
    end
end

function load_vault()
    isfile(VAULT_FILE) || return
    try
        data = JSON.parsefile(VAULT_FILE)
        for d in data
            vault_store!(d["domain"],d["focus"],d["content"],d["priority"])
        end
        clog("Vault loaded: $(length(VAULT)) nodes")
    catch e
        clog("Vault load error: $e"; level="WARN")
    end
end

# ==============================================================================
# MODULE 2: DISCOVERY LOOP — Google API → Vault
# ==============================================================================
function google_search(query::String)::Vector{String}
    isempty(GOOGLE_KEY) && return String[]
    try
        url  = "https://www.googleapis.com/customsearch/v1?q=$(HTTP.URIs.escapeuri(query))&key=$GOOGLE_KEY&cx=$GOOGLE_CX&num=5"
        resp = HTTP.get(url; readtimeout=15)
        data = JSON.parse(String(resp.body))
        items = get(data,"items",Any[])
        return [string(get(item,"snippet","")) for item in items]
    catch e
        clog("Google search error: $e"; level="WARN")
        return String[]
    end
end

function run_discovery_loop()
    clog("Discovery loop starting...")
    isfile(KNOWLEDGE_CSV) || (clog("No knowledge CSV found"; level="WARN"); return)

    # Use strict=false to ignore row 14 formatting errors
df = CSV.read(KNOWLEDGE_CSV, DataFrame; 
              comment="#", 
              silencewarnings=true, 
              strict=false)

    # Sort by priority: Critical first
    priority_order = Dict("Critical"=>1,"High"=>2,"Medium"=>3,"Low"=>4)
    sorted_rows = sort(collect(eachrow(df)),
                       by=r->get(priority_order,
                                 string(get(r,"Creator_Priority","Low")),4))

    cycle = 0
    while true
        cycle += 1
        clog("Discovery cycle $cycle — $(length(sorted_rows)) domains to learn")

        for row in sorted_rows
            try
    domain   = string(get(row, "Domain", "")) # Cast to string to fix MethodError
    focus    = string(get(row, "Focus_Area", ""))
    priority = string(get(row, "Creator_Priority", "High"))

    # Instead of results = google_search(query)
    # Redirect to your custom "Transformer Scout" output
    scout_path = joinpath(IGGY_DIR, "scout_buffer.json")
    
    if isfile(scout_path)
        # Load data found by your human-impersonator scout
        results = JSON.parsefile(scout_path) 
    else
        # Fallback to local knowledge if scout hasn't run[cite: 2]
        results = String[]
    end

                sleep(1.5)   # Respect Google rate limits

            catch e
                clog("Discovery error: $e"; level="WARN")
                sleep(5)
            end
        end

        save_vault()
        clog("Discovery cycle $cycle complete. Vault: $(length(VAULT)) nodes")
        tg("Learning cycle $cycle complete. $(length(VAULT)) knowledge nodes stored.")

        sleep(3600)   # Run again every hour
    end
end

# ==============================================================================
# MODULE 3: TRADING ENGINE — Stratosphere Core
# ==============================================================================
mutable struct Strategy
    weights::Matrix{Float32}
    fitness::Float32
    age::Int
end

mutable struct IGGYCore
    W_h::Matrix{Float32}
    W_x::Matrix{Float32}
    h_state::Vector{Float32}
    short_mem::Vector{Float32}
    long_mem::Vector{Float32}
    strategies::Vector{Strategy}
    volatility_gate::Float32
end

global TOTAL_TRADES = 0
const TRADE_LOCK    = ReentrantLock()

function log_trade(ts,symbol,side,qty,price)
    lock(TRADE_LOCK) do
        if !isfile(LOG_FILE)
            open(LOG_FILE,"w") do f; write(f,"Timestamp,Symbol,Side,Qty,Price\n"); end
        end
        open(LOG_FILE,"a") do f; write(f,"$ts,$symbol,$side,$qty,$price\n"); end
    end
end

function ternary_snap(W::Matrix{Float32})::Matrix{Float32}
    α = mean(abs,W)
    return sign.(W) .* (abs.(W) .> (0.7f0*α))
end

function layer_norm(h::Vector{Float32})::Vector{Float32}
    μ=mean(h); σ=std(h)+1f-8; return (h.-μ)./σ
end

function init_core()::IGGYCore
    d=HIDDEN_DIM; s=Float32(sqrt(2.0/d))
    strats = [Strategy(randn(Float32,1,d)*0.1f0,0.0f0,0) for _ in 1:POPULATION]
    IGGYCore(ternary_snap(randn(Float32,d,d)*s),
             ternary_snap(randn(Float32,d,Z_CHUNK)*s),
             zeros(Float32,d),zeros(Float32,d),zeros(Float32,d),
             strats,1.0f0)
end

function execute_trade!(side::String, symbol::String, quantity::Real)
    isempty(BINANCE_KEY) && return
    try
        st    = JSON.parse(String(HTTP.get(BASE_URL*"/api/v3/time").body))["serverTime"]
        qty   = if symbol=="SOLUSDT" && quantity<0.1; 0.2
                elseif symbol=="BNBUSDT" && quantity<0.02; 0.05
                else; quantity; end
        query = "symbol=$symbol&side=$side&type=MARKET&quantity=$qty&recvWindow=10000&timestamp=$st"
        sig   = bytes2hex(hmac_sha256(Vector{UInt8}(BINANCE_SEC),Vector{UInt8}(query)))
        res   = JSON.parse(String(HTTP.post(
                    "$BASE_URL/api/v3/order?$query&signature=$sig",
                    ["X-MBX-APIKEY"=>BINANCE_KEY]).body))

        if haskey(res,"fills") && !isempty(res["fills"])
            price = res["fills"][1]["price"]
            ts    = Dates.format(now(),"yyyy-mm-dd HH:MM:SS")
            clog("[TRADE] $side $symbol @ $price")
            log_trade(ts,symbol,side,qty,price)
            tg("$side $symbol @ \$$price | Trade #$(TOTAL_TRADES+1)")
            global TOTAL_TRADES; TOTAL_TRADES += 1
            TOTAL_TRADES >= TARGET_TRADES &&
                tg("TARGET REACHED ($TARGET_TRADES trades). Validated.")
        end
    catch e; clog("Trade failed $symbol: $e"; level="WARN"); end
end

function step_logic!(core::IGGYCore, cur::Float32, last::Float32,
                     symbol::String)::Float32
    vel = (cur-last)/last

    # Vault-enhanced signal — query relevant knowledge
    vault_context = vault_query("$symbol trading signal momentum volatility")
    vault_boost   = isempty(vault_context) ? 0.0f0 :
                    Float32(length(vault_context)) * 0.05f0

    core.volatility_gate = 0.95f0*core.volatility_gate +
                           0.05f0*(abs(vel)>0.001f0 ? 0.9f0 : 1.0f0)

    input_vec    = fill(Float32(vel),Z_CHUNK)
    core.h_state = tanh.(core.W_h*core.h_state + core.W_x*input_vec)
    core.h_state = layer_norm(core.h_state) .* core.volatility_gate

    core.short_mem = 0.8f0.*core.short_mem .+ 0.2f0.*core.h_state
    core.long_mem  = 0.99f0.*core.long_mem .+ 0.01f0.*core.h_state

    best_fit=−Inf32; winner_idx=1
    for (i,s) in enumerate(core.strategies)
        conf      = (s.weights*core.h_state)[1]
        s.fitness = conf*sign(vel)
        if s.fitness>best_fit; best_fit=s.fitness; winner_idx=i; end
        s.age += 1
    end
    for i in 1:POPULATION
        i==winner_idx && continue
        core.strategies[i].weights +=
            (core.strategies[winner_idx].weights - core.strategies[i].weights)*0.05f0
        rand()>0.9 &&
            (core.strategies[i].weights += randn(Float32,1,HIDDEN_DIM)*0.01f0)
    end

    raw_conf = (core.strategies[winner_idx].weights*core.h_state)[1]
    # Vault knowledge amplifies confidence when signal aligns
    return raw_conf + (sign(raw_conf)*vault_boost)
end

function run_trading_loop()
    clog("Trading engine starting...")
    core        = init_core()
    watchlist   = ["BTCUSDT","ETHUSDT","BNBUSDT","SOLUSDT"]
    last_prices = Dict(s=>0.0f0 for s in watchlist)

    tg("Stratosphere online. Vault-enhanced trading active.")

    while true
        for sym in watchlist
            try
                resp  = HTTP.get(BASE_URL*"/api/v3/ticker/price?symbol=$sym")
                price = parse(Float32,JSON.parse(String(resp.body))["price"])

                if last_prices[sym]!=0.0f0 &&
                   abs(price-last_prices[sym])/last_prices[sym] > MIN_MOVE

                    conf = step_logic!(core,price,last_prices[sym],sym)

                    if abs(conf) > THRESHOLD
                        side = conf>0 ? "BUY" : "SELL"
                        qty  = sym=="BTCUSDT" ? 0.001 : 0.01
                        execute_trade!(side,sym,qty)
                    end

                    @printf("[%s] %-8s | Conf:%7.4f | Vault:%d | Trades:%d/%d\n",
                            Dates.format(now(),"HH:MM:SS"),
                            sym, conf, length(VAULT),
                            TOTAL_TRADES, TARGET_TRADES)
                end
                last_prices[sym] = price
            catch e; clog("$sym error: $e"; level="WARN"); end
            sleep(0.1)
        end
    end
end

# ==============================================================================
# MODULE 4: HOURLY REPORT
# ==============================================================================
function run_report_loop()
    sleep(3600)
    while true
        try
            vault_size = length(VAULT)
            critical   = count(n->n.priority=="Critical", VAULT)
            msg = """
Hourly Report:
Trades: $TOTAL_TRADES/$TARGET_TRADES
Knowledge nodes: $vault_size ($critical critical)
Uptime: $(Dates.format(now(),"HH:MM dd u yyyy"))
"""
            tg(msg)
            save_vault()
        catch e
            clog("Report error: $e"; level="WARN")
        end
        sleep(3600)
    end
end

# ==============================================================================
# MAIN — Start all modules as async tasks
# ==============================================================================
function run_iggy_cns()
    
    println("="^60)
    println("  PROJECT IGGY — CENTRAL NERVOUS SYSTEM v2.0")
    println("  Modules: Trading + Discovery + Vault + Reports")
    println("  Knowledge domains: $(isfile(KNOWLEDGE_CSV) ? "loaded" : "missing")")
    println("="^60)

    # Load existing vault
    load_vault()

    tg("CNS v2.0 online. All modules starting.")

    # Launch all modules as non-blocking async tasks
    @async run_discovery_loop()
    @async run_report_loop()

    # Trading runs in main thread (needs to be responsive)
    run_trading_loop()
end

run_iggy_cns()
