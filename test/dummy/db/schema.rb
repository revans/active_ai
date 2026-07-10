# Hand-written to mirror the generator templates in
# lib/generators/active_ai/memory/templates/migrations/ — the dummy app has no
# migrations of its own (maintain_test_schema is false), so this is loaded
# directly by test_helper.rb against the in-memory sqlite test database.
ActiveRecord::Schema.define do
  create_table :active_ai_memories, force: true do |t|
    t.string   :user_type
    t.bigint   :user_id
    t.string   :subject_type
    t.bigint   :subject_id
    t.string   :agent_class, null: false
    t.string   :scope
    t.string   :tier, null: false, default: "warm"
    t.text     :summary, null: false, default: "{}"
    t.integer  :token_estimate
    t.integer  :access_count, null: false, default: 0
    t.datetime :last_accessed_at
    t.datetime :promoted_at
    t.float    :confidence, null: false, default: 1.0
    t.timestamps
  end

  add_index :active_ai_memories, [:user_type, :user_id, :agent_class], name: "idx_aim_user_agent"
  add_index :active_ai_memories, [:subject_type, :subject_id, :agent_class], name: "idx_aim_subject_agent"
  add_index :active_ai_memories, [:user_type, :user_id, :subject_type, :subject_id, :agent_class, :scope], name: "idx_aim_full_lookup"
  add_index :active_ai_memories, [:tier, :last_accessed_at], name: "idx_aim_tier_access"
  add_index :active_ai_memories, [:agent_class, :subject_type, :subject_id], name: "idx_aim_agent_subject"

  create_table :active_ai_memory_embeddings, force: true do |t|
    t.bigint   :memory_id, null: false
    t.string   :vector_id, null: false
    t.string   :vector_store, null: false, default: "pgvector"
    t.text     :embedding
    t.datetime :embedded_at
    t.timestamps
  end

  add_index :active_ai_memory_embeddings, :vector_id
  add_index :active_ai_memory_embeddings, [:memory_id, :vector_store], unique: true

  create_table :active_ai_memory_correlations, force: true do |t|
    t.bigint :memory_a_id, null: false
    t.bigint :memory_b_id, null: false
    t.float  :similarity_score
    t.string :correlation_type
    t.timestamps
  end

  add_index :active_ai_memory_correlations, [:memory_a_id, :memory_b_id], unique: true, name: "idx_aim_correlation_pair"
  add_index :active_ai_memory_correlations, :memory_b_id

  create_table :active_ai_memory_flags, force: true do |t|
    t.bigint :memory_id, null: false
    t.string :flag_type, null: false
    t.text   :reason
    t.float  :confidence_at_flag
    t.string :status, null: false, default: "pending"
    t.timestamps
  end

  add_index :active_ai_memory_flags, [:memory_id, :flag_type]
  add_index :active_ai_memory_flags, [:status, :flag_type]
end
