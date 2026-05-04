using HTTP, JSON, Printf

function get_live_btc_price()
    println("📡 Connecting directly to Binance API...")
    
    # Binance Public API Endpoint
    url = "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT"
    
    try
        response = HTTP.get(url)
        
        # Check if the request was successful
        if response.status == 200
            data = JSON.parse(String(response.body))
            price = data["price"]
            println("✅ CONNECTION SUCCESSFUL")
            println("Current BTC Price: \$", price)
        else
            println("❌ API Returned Status: ", response.status)
        end
    catch e
        println("❌ CONNECTION FAILED")
        @show e
    end
end

get_live_btc_price()