# ActiveAIMemoryFlag — marks a memory as needing review.
#
# Table: active_ai_memory_flags
# flag_type: "contradiction" | "superseded" | etc.
# status: "pending" | "resolved" | "dismissed"
class ActiveAIMemoryFlag < ApplicationRecord
  belongs_to :memory, class_name: "ActiveAIMemory", foreign_key: :memory_id

  validates :flag_type, presence: true
end
