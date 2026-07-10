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

  # SQLite has no jsonb; there this column is `text`, so without an explicit
  # serialize, assigning a Hash stores Ruby's Hash#to_s (single-quoted, `=>`
  # syntax) instead of JSON, and Memory::Formatter's `JSON.parse` on read
  # blows up on the very next recall. Postgres' native jsonb column already
  # round-trips a Hash on its own — declaring `serialize` on top of that is
  # what Rails now raises ColumnNotSerializableError for, rather than quietly
  # double-handling it. Host apps that migrate this column to jsonb (see
  # ChangeSummaryToJsonb) need `serialize` to switch off accordingly, so this
  # checks the actual column type instead of assuming SQLite == text.
  serialize :summary, coder: JSON if columns_hash["summary"].sql_type.casecmp?("text")

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
