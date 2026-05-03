# ==============================================================================
# IGGY DATA TEACHER v1.0 — Binance Data Harvester
# ==============================================================================

using Downloads, Dates

function download_binance_history(symbol="BTCUSDT", limit=500)
    println("[TEACHER] Fetching $limit candles for $symbol...")
    url = "https://api.binance.com/api/v3/klines?symbol=$symbol&interval=15m&limit=$limit"
    
    try
        buf = IOBuffer()
        Downloads.download(url, buf)
        raw_data = String(take!(buf))
        
        # Save raw data for IGGY to "read" later
        open("market_data.json", "w") do f
            write(f, raw_data)
        end
        println("[TEACHER] Data saved to market_data.json. IGGY can now begin Phase 3.")
    catch e
        println("[ERROR] Failed to reach Binance: $e")
    end
end

download_binance_history()