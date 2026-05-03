module IggyVault
using SHA, LinearAlgebra, Dates

struct MemoryNode
    timestamp::DateTime
    vector::Vector{Float32}
    content::String
end

mutable struct SovereignMemory
    nodes::Vector{MemoryNode}
end

function encode(text::String)
    v = zeros(Float32, 64)
    h = sha256(lowercase(text))
    for (i, b) in enumerate(h)
        v[(i%64)+1] += (Int(byte(b)) > 127 ? 1.0f0 : -1.0f0)
    end
    return v ./ (norm(v) + 1e-8)
end

function remember!(m::SovereignMemory, txt::String)
    push!(m.nodes, MemoryNode(now(), encode(txt), txt))
end

function recall(m::SovereignMemory, query::String; k=1)
    qv = encode(query)
    scores = [(dot(qv, n.vector), n) for n in m.nodes]
    sort!(scores, by=x->x[1], rev=true)
    return [s[2] for s in scores[1:min(end, k)]]
end

function boot_memory()
    return SovereignMemory(Vector{MemoryNode}())
end
end
