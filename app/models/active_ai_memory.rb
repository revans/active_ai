# ActiveAIMemory — persisted memory record for the ActiveAI Memory system.
#
# Table: active_ai_memories
# Named ActiveAIMemory (not namespaced) to match Rails convention:
#   active_ai_memories table → ActiveAIMemory class
#
# Do not confuse with the app-level Memory model (table: memories).
# They are entirely separate systems.
class ActiveAIMemory < ApplicationRecord
  VALID_TIERS = %w[warm cold].freeze

  has_many :active_ai_memory_embeddings, foreign_key: :memory_id, dependent: :destroy
  has_many :active_ai_memory_flags,      foreign_key: :memory_id, dependent: :destroy

  validates :agent_class, presence: true
  validates :summary,     exclusion: { in: [nil], message: "can't be blank" }
  validates :tier,        inclusion: { in: VALID_TIERS, message: "must be warm or cold" }

  scope :warm, -> { where(tier: "warm") }
  scope :cold, -> { where(tier: "cold") }
end
