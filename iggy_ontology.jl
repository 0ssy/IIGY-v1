# iggy_ontology.jl
module IggyOntology

# Entity Types
const TYPE_ASSET = :Asset
const TYPE_USER = :User
const TYPE_PROJECT = :Project

# Predicates (Relationships)
const PRED_IN_REGIME = :isInRegime
const PRED_OWNS = :owns
const PRED_PREDICTS = :predicts
const PRED_CONNECTED_TO = :isConnectedTo

println("📜 IGGY: Ontology definitions loaded.")
end