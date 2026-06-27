# ActiveAIMemoryCorrelation — tracks similarity relationships between memories.
#
# Table: active_ai_memory_correlations
# Constraint: memory_a_id must be less than memory_b_id.
# This prevents duplicate pairs (A,B) and (B,A) from both existing.
class ActiveAIMemoryCorrelation < ApplicationRecord
  belongs_to :memory_a, class_name: "ActiveAIMemory", foreign_key: :memory_a_id
  belongs_to :memory_b, class_name: "ActiveAIMemory", foreign_key: :memory_b_id

  validates :memory_a_id, presence: true
  validates :memory_b_id, presence: true
  validate  :memory_a_id_less_than_memory_b_id

  private

  def memory_a_id_less_than_memory_b_id
    return unless memory_a_id.present? && memory_b_id.present?
    errors.add(:memory_a_id, "must be less than memory_b_id") if memory_a_id >= memory_b_id
  end
end
