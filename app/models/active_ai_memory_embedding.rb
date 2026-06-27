# ActiveAIMemoryEmbedding — tracks which memories have been embedded and where.
#
# Table: active_ai_memory_embeddings
class ActiveAIMemoryEmbedding < ApplicationRecord
  has_neighbors :embedding

  belongs_to :memory, class_name: "ActiveAIMemory", foreign_key: :memory_id

  validates :vector_id,    presence: true
  validates :vector_store, presence: true
end
