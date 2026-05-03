# ==============================================================================
# PROJECT IGGY — THE SPEECH ENGINE v1.1 (Sovereign Interpreter)
# ==============================================================================
using Flux, Serialization, StatsBase

# ── 0. CONFIGURATION ─────────────────────────────────────────────────────────
const BRAIN_PATH = "iggy_brain_v1.bin"
const DATA_PATH = joinpath(@__DIR__, "SovereignData")

# ── 1. RECONSTRUCT THE DICTIONARY (ENCODING ALIGNMENT) ───────────────────────
function get_vocab()
    raw_data = ""
    # We must iterate through the same files used in the Forge phase
    for file in readdir(DATA_PATH)
        if endswith(file, ".txt") || endswith(file, ".jl")
            # Explicit UTF-8 reading to ensure math symbols (√, ∝) align with IDs
            raw_data *= read(joinpath(DATA_PATH, file), String)
        end
    end
    unique_chars = sort(collect(Set(raw_data)))
    # Create both maps for bidirectional translation
    id_to_char = Dict(i => c for (i, c) in enumerate(unique_chars))
    char_to_id = Dict(c => i for (i, c) in enumerate(unique_chars))
    return id_to_char, char_to_id
end

# ── 2. THE SPEECH LOGIC ──────────────────────────────────────────────────────
function ignite_speech(start_char::Char, len=200; temp=1.2, penalty=15.0)
    # Load assets
    id_to_char, char_to_id = get_vocab()
    
    if !isfile(BRAIN_PATH)
        println("[!] ERROR: Brain file missing. Run the trainer first.")
        return
    end
    
    model = deserialize(BRAIN_PATH)
    start_id = get(char_to_id, start_char, 1)
    
    Flux.reset!(model)
    println("--- IGGY SPEECH ENGINE v1.1 ---")
    println(">>> [CONFIG]: Temp=$temp, Penalty=$penalty")
    print(">>> [PROMPT]: $start_char \n>>> [IGGY]: ")
    
    current_token = [start_id;;] 
    history = Int[] # Track long-term history to prevent symbol sinks

    for i in 1:len
        # 1. Forward pass through ternary neurons
        output = model(current_token)
        logits = vec(output)
        
        # 2. REPETITION PENALTY (History Window: 20)
        # We aggressively lower the score of recently used characters
        for id in unique(history[max(1, end-20):end])
            logits[id] -= penalty
        end
        
        # 3. STABLE SOFTMAX (Log-Sum-Exp Trick)
        # Prevents Inf/NaN when the ternary activations explode
        shifted = (logits .- maximum(logits)) ./ temp
        exp_logits = exp.(shifted)
        probs = exp_logits ./ sum(exp_logits)
        
        # 4. SAMPLING
        try
            next_id = sample(1:length(probs), Weights(probs))
            
            # 5. TRANSLATION & DISPLAY
            c = get(id_to_char, next_id, '\0')
            print(c)
            
            # 6. UPDATE STATE
            push!(history, next_id)
            current_token = [next_id;;]
        catch e
            # Fallback for mathematical instability
            next_id = rand(1:length(logits))
            current_token = [next_id;;]
        end
    end
    println("\n--- END OF TRANSMISSION ---")
end

# ── 3. EXECUTION ─────────────────────────────────────────────────────────────
# Try prompts like 'f' (function), 'D' (Discrete), or 'u' (using)
ignite_speech('f', 250, temp=1.2, penalty=15.0)