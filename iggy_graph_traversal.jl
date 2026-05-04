# iggy_graph_traversal.jl
module IggyTraversal

function find_path(kg, start_id::Symbol, end_id::Symbol)
    queue = [(start_id, [start_id])]
    visited = Set([start_id])
    
    while !isempty(queue)
        (current, path) = popfirst!(queue)
        if current == end_id return path end
        
        # Check neighbors
        for rel in kg.relationships
            if rel.source == current && !(rel.target in visited)
                push!(visited, rel.target)
                push!(queue, (rel.target, [path..., rel.target]))
            end
        end
    end
    return nothing
end
end