using HTTP, JSON, SHA, Dates, Printf

# 1. Helpers
function hmac_sha256_hex(key, msg)
    return bytes2hex(hmac_sha256(Vector{UInt8}(key), Vector{UInt8}(msg)))
end

# 2. The Execution Logic (Now takes URL and Keys as arguments)
function place_test_order(url_base, api_key, api_secret, side, quantity)
    endpoint = "/api/v3/order/test"
    full_target_url = url_base * endpoint
    
    # Get Timestamp
    timestamp = Int64(floor(datetime2unix(now(Dates.UTC)) * 1000))
    
    # Build Query
    query_string = "symbol=BTCUSDT&side=$side&type=MARKET&quantity=$quantity&timestamp=$timestamp&recvWindow=5000"
    
    # Create Signature
    signature = hmac_sha256_hex(api_secret, query_string)
    
    headers = ["X-MBX-APIKEY" => api_key]
    final_request_url = "$full_target_url?$query_string&signature=$signature"
    
    println("📡 Connecting to: $url_base")
    
    try
        response = HTTP.post(final_request_url, headers)
        if response.status == 200
            println("✅ SUCCESS: Order logic validated on Demo/Testnet.")
        end
    catch e
        if e isa HTTP.ExceptionRequest.StatusError
            println("❌ REJECTED: ", String(e.response.body))
        else
            @show e
        end
    end
end

# 3. Main Entry Point (Define variables here and pass them in)
function main()
    # Fetch from environment
    key = get(ENV, "BINANCE_API_KEY", "")
    secret = get(ENV, "BINANCE_API_SECRET", "")
    base = "https://testnet.binance.vision"

    if key == "" || secret == ""
        println("❌ ERROR: Keys missing. Run \$Env:BINANCE_API_KEY = '...' in PowerShell.")
        return
    end

    # EXECUTE
    place_test_order(base, key, secret, "BUY", 0.005)
end

# Run the main function
main()