# ==============================================================================
# PROJECT IGGY — THE REFLEX ENGINE v1.2 (Sovereign Loop-Breaker)
# ==============================================================================
using Flux, Serialization, StatsBase

const BRAIN_PATH = "iggy_brain_v1.bin"

println("--- AWAKENING IGGY: LOADING REFLEX ENGINE v1.2 ---")
if !isfile(BRAIN_PATH)
    exit()
end

model = deserialize(BRAIN_PATH)

function generate_reflex(start_id::Int, len=60; temperature=1.0f0, penalty=2.0f0)
    Flux.reset!(model)
    println(">>> PROMPT ID: ", start_id)
    print(">>> IGGY REFLEX: ")
    
    current_token = [start_id;;] 
    generated_history = Int[] # Track history to penalize loops

    for i in 1:len
        output = model(current_token)
        logits = vec(output)
        
        # --- LOOP BREAKER: Repetition Penalty ---
        # We look at the last 5 tokens and penalize their scores
        for id in unique(generated_history[max(1, end-5):end])
            logits[id] -= penalty
        end
        
        # --- STABILITY: Shifted Softmax ---
        shifted_logits = (logits .- maximum(logits)) ./ temperature
        exp_logits = exp.(shifted_logits)
        prob_dist = exp_logits ./ sum(exp_logits)
        
        try
            next_token_id = sample(1:length(prob_dist), Weights(prob_dist))
            
            print(next_token_id, " ")
            push!(generated_history, next_token_id)
            current_token = [next_token_id;;]
        catch e
            next_token_id = argmax(logits) # Fallback
            print(next_token_id, " ")
            current_token = [next_token_id;;]
        end
    end
    println("\n--- REFLEX COMPLETE ---")
end

# We increase the penalty slightly to ensure the "109" is avoided
generate_reflex(1, 60, temperature=1.1f0, penalty=5.0f0)