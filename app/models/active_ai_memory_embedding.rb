# ActiveAIMemoryEmbedding — tracks which memories have been embedded and where.
#
# Table: active_ai_memory_embeddings
class ActiveAIMemoryEmbedding < ApplicationRecord
  # `neighbor` is an optional dependency (added to the host app's Gemfile only
  # when running `active_ai:memory:install --vector=pgvector`, see that
  # generator's add_neighbor_gem step) — without this guard, any app that
  # installs the base memory system without also adding `neighbor` gets a
  # hard NoMethodError the moment this model is first autoloaded.
  has_neighbors :embedding if respond_to?(:has_neighbors)

  belongs_to :memory, class_name: "ActiveAIMemory", foreign_key: :memory_id

  validates :vector_id,    presence: true
  validates :vector_store, presence: true
end
