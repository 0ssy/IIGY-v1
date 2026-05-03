# ==============================================================================
# PROJECT IGGY — THE UNIVERSAL FORGE v2.6
# Fix: MethodError: no method matching isless(::Float32, ::Nothing)
# ==============================================================================
using Flux, Serialization, Random, StatsBase, Printf, Statistics

# ── 1. CONFIGURATION ─────────────────────────────────────────────────────────
const DATA_DIR = joinpath(@__DIR__, "SovereignData")
const MODEL_SAVE_PATH = "iggy_brain_v1.bin"

const HIDDEN_SIZE = 256     
const BATCH_SIZE = 32       
const SEQ_LEN = 128         
const EPOCHS = 100
const LEARNING_RATE = 0.001

# ── 2. DATA HANDLING ─────────────────────────────────────────────────────────
function load_universal_vocab(path)
    all_text = ""
    for file in readdir(path)
        if endswith(file, ".txt") || endswith(file, ".jl")
            all_text *= read(joinpath(path, file), String)
        end
    end
    chars = sort(collect(Set(all_text)))
    char_to_id = Dict(c => i for (i, c) in enumerate(chars))
    id_to_char = Dict(i => c for (i, c) in enumerate(chars))
    return char_to_id, id_to_char, length(chars)
end

function get_batch(data_ids, vocab_size)
    X = zeros(Int, SEQ_LEN, BATCH_SIZE)
    Y = zeros(Int, SEQ_LEN, BATCH_SIZE)
    
    for i in 1:BATCH_SIZE
        start_idx = rand(1:(length(data_ids) - SEQ_LEN))
        X[:, i] = data_ids[start_idx : start_idx + SEQ_LEN - 1]
        Y[:, i] = data_ids[start_idx + 1 : start_idx + SEQ_LEN]
    end
    return X, Y
end

# ── 3. TERNARY WEIGHT SNAP (GRADUAL CRYSTALLIZATION) ─────────────────────────
function ternary_snap!(model, current_epoch)
    # Delay snapping further to allow the model to reach a stable minima
    if current_epoch > 25 
        for p in Flux.trainable(model)
            if p isa AbstractArray
                # Calculate threshold based on the actual distribution of weights
                # Using a 1.5x mean threshold to be less aggressive than before
                avg_abs = mean(abs, p)
                threshold = 1.5f0 * avg_abs 
                
                # Apply the snap
                p .= ifelse.(p .> threshold, 1.0f0, 
                      ifelse.(p .< -threshold, -1.0f0, 0.0f0))
            end
        end
    end
end

# ── 4. ARCHITECTURE: LINEAR RECURRENCE ENGINE ────────────────────────────────
function build_iggy(vocab_size)
    return Chain(
        Embedding(vocab_size => 64),
        RNN(64 => HIDDEN_SIZE, relu), 
        Dense(HIDDEN_SIZE, vocab_size)
    )
end

# ── 5. HELPER: TYPE-SAFE GRADIENT CLIPPING ───────────────────────────────────
# Fixed to ignore 'Nothing' types in the gradient tree
function clip_grads!(grads, threshold)
    return fmap(grads) do g
        if g isa AbstractArray
            return clamp.(g, -threshold, threshold)
        end
        return g # Return 'Nothing' or other non-arrays as-is
    end
end

# ── 6. THE FORGE ─────────────────────────────────────────────────────────────
function forge_sovereign_agent()
    println("--- INITIALIZING STABLE FORGE v2.6 ---")
    
    if !isdir(DATA_DIR)
        mkdir(DATA_DIR)
        println("[!] Created SovereignData folder. Add your notes and restart.")
        return
    end

    char_to_id, id_to_char, vocab_size = load_universal_vocab(DATA_DIR)
    
    full_data_ids = Int[]
    for file in readdir(DATA_DIR)
        content = read(joinpath(DATA_DIR, file), String)
        append!(full_data_ids, [get(char_to_id, c, 1) for c in content])
    end

    model = build_iggy(vocab_size)
    opt_state = Flux.setup(Adam(LEARNING_RATE), model)

    println("FORGING: $(length(full_data_ids)) tokens | Vocab: $vocab_size")

    for epoch in 1:EPOCHS
        total_loss = 0.0
        
        for _ in 1:100 
            X_batch, Y_batch = get_batch(full_data_ids, vocab_size)
            
            val, grads = Flux.withgradient(model) do m
                Flux.reset!(m)
                l = 0.0f0
                for t in 1:SEQ_LEN
                    y_true = Flux.onehotbatch(Y_batch[t, :], 1:vocab_size)
                    y_hat = m(X_batch[t, :])
                    l += Flux.logitcrossentropy(y_hat, y_true)
                end
                return l / SEQ_LEN
            end
            
            # Apply Type-Safe Gradient Clipping
            clipped_grads = clip_grads!(grads, 0.5f0)
            Flux.update!(opt_state, model, clipped_grads[1])
            
            total_loss += val
            ternary_snap!(model, epoch)
        end
        
        @printf("Epoch %d | Loss: %.4f\n", epoch, total_loss / 100)
        
        if epoch % 5 == 0
            serialize(MODEL_SAVE_PATH, model)
            println(">> Brain Checkpoint Crystallized.")
        end
    end
    
    serialize(MODEL_SAVE_PATH, model)
    println("--- FORGE COMPLETE ---")
end

forge_sovereign_agent()