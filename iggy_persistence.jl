# iggy_persistence.jl
module IggyPersistence
using JSON, Dates

function save_brain(kg, fm, filename="iggy_brain.json")
    data = Dict(
        "timestamp" => string(now()),
        "confidence" => fm.confidence,
        "rule_weights" => fm.rule_weights,
        "entities" => [Dict(:id => e.id, :type => e.type, :props => e.properties) for e in values(kg.entities)],
        "relationships" => [Dict(:s => r.source, :t => r.target, :type => r.type, :props => r.properties) for r in kg.relationships]
    )
    open(filename, "w") do f
        JSON.print(f, data)
    end
    println("💾 IGGY: State persisted to $filename")
end

function load_brain!(kg, fm, filename="iggy_brain.json")
    if !isfile(filename) return println("⚠️ No save file found. Starting fresh.") end
    data = JSON.parsefile(filename)
    fm.confidence = data["confidence"]
    # Reconstruct logic goes here to repopulate structs
    println("🧠 IGGY: Brain state loaded from $(data["timestamp"])")
end
end