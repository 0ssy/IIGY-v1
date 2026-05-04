using HTTP, JSON, SHA, Dates, Printf

# 1. Credentials
const API_KEY = get(ENV, "BINANCE_API_KEY", "")
const API_SECRET = get(ENV, "BINANCE_API_SECRET", "")

# 2. Authentication Helper (The "Signature")
function hmac_sha256_hex(key, msg)
    # Corrected HMAC call for Julia's SHA library
    return bytes2hex(hmac_sha256(Vector{UInt8}(key), Vector{UInt8}(msg)))
end

# 3. The Test Order Function
function place_test_order(side, quantity)
    url = "https://api.binance.com/api/v3/order/test"
    
    # Corrected Timestamp logic
    timestamp = Int64(floor(datetime2unix(now(Dates.UTC)) * 1000))
    
    # Constructing Query
    query_string = "symbol=BTCUSDT&side=$side&type=MARKET&quantity=$quantity&timestamp=$timestamp"
    signature = hmac_sha256_hex(API_SECRET, query_string)
    
    headers = ["X-MBX-APIKEY" => API_KEY]
    full_url = "$url?$query_string&signature=$signature"
    
    try
        # POST request to the test endpoint
        response = HTTP.post(full_url, headers)
        if response.status == 200
            println("✅ TEST ORDER VALIDATED: $side $quantity BTC")
            println("Your API Signature logic is 100% correct.")
        end
    catch e
        println("❌ TEST ORDER FAILED")
        if e isa HTTP.ExceptionRequest.StatusError
            # This extracts the actual error message from Binance (e.g., "MIN_NOTIONAL")
            println("Binance Message: ", String(e.response.body))
        else
            @show e
        end
    end
end

# Ensure keys are present before trying
if API_KEY != "" && API_SECRET != ""
    place_test_order("BUY", 0.001)
else
    println("❌ Error: API_KEY or API_SECRET environment variables are missing.")
end