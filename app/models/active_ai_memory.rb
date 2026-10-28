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

  # summary is `text` on SQLite and `jsonb` on PostgreSQL (or after ChangeSummaryToJsonb).
  # The JSON type writes a JSON string, which both columns accept, and parses it back, so
  # a Hash round-trips either way. Not `serialize`, which Rails refuses on a json column,
  # and not a column-type check either: production eager loads this class at boot, and
  # asking the database then keeps an app from starting without a connection.
  attribute :summary, :json

  has_many :active_ai_memory_embeddings, foreign_key: :memory_id, dependent: :destroy
  has_many :active_ai_memory_flags,      foreign_key: :memory_id, dependent: :destroy

  validates :agent_class, presence: true
  validates :summary,     exclusion: { in: [nil], message: "can't be blank" }
  validates :tier,        inclusion: { in: VALID_TIERS, message: "must be warm or cold" }

  scope :warm,               -> { where(tier: "warm") }
  scope :cold,               -> { where(tier: "cold") }
  scope :frequently_accessed, -> { where("access_count >= ?", 10) }
  scope :dormant,             -> { where("last_accessed_at < ?", 30.days.ago) }
  scope :most_accessed,       -> { order(access_count: :desc) }
  scope :recently_accessed,   -> { order(last_accessed_at: :desc) }
end
