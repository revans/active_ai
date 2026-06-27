module ActiveAI
  module Memory
    EMPTY_SUMMARY = {
      "decisions"          => [],
      "open_threads"       => [],
      "identity_updates"   => [],
      "resolved"           => [],
      "agent_observations" => []
    }.freeze

    # Returns memories ordered by specificity score, truncated to token_budget.
    #
    # strategy: :warm  — key-lookup of warm memories only (default)
    # strategy: :cold  — vector similarity search across cold memories only
    # strategy: :hybrid — warm key-lookup first, then cold vector search seeded
    #                     by the warm results' embeddings; warm scores weighted 1.2x
    #
    # Specificity scoring: each matched non-nil dimension scores 1 point (max 4).
    # A nil argument is a wildcard — no filter applied for that dimension.
    # Within the same score, ordered by last_accessed_at desc.
    #
    # Side effect: increments access_count and sets last_accessed_at on returned records.
    def self.recall(user: nil, agent: nil, subject: nil, scope: nil,
                    strategy: :warm, token_budget: 800)
      case strategy
      when :warm   then warm_recall(user, agent, subject, scope, token_budget)
      when :cold   then cold_recall(user, agent, subject, scope, token_budget)
      when :hybrid then hybrid_recall(user, agent, subject, scope, token_budget)
      else raise ArgumentError, "Unknown recall strategy: #{strategy.inspect}. Use :warm, :cold, or :hybrid."
      end
    end

    # Upserts a memory record on (user, agent, subject, scope).
    # When async: true (default), enqueues EmbedJob after persist.
    # Returns the persisted ActiveAIMemory record.
    def self.persist(user: nil, agent: nil, subject: nil, scope: nil,
                     summary:, async: true)
      attrs = build_lookup_attrs(user, agent, subject, scope)
      memory = ActiveAIMemory.find_or_initialize_by(attrs)
      memory.summary         = summary
      memory.token_estimate  = estimate_tokens(summary)
      memory.save!

      ActiveAIMemoryEmbedJob.perform_later(memory.id) if async

      memory
    end

    private

    # --- Recall strategies ---

    def self.warm_recall(user, agent, subject, scope, token_budget)
      relation = build_relation(ActiveAIMemory.warm, user, agent, subject, scope)
      ranked   = rank(relation.to_a, user, agent, subject, scope)
      selected = select_within_budget(ranked, token_budget)
      touch_access(selected) if selected.any?
      selected
    end

    def self.cold_recall(user, agent, subject, scope, token_budget)
      # Cold recall requires at least one seed embedding. Without a warm anchor
      # there's no vector to search from — return empty rather than a full table scan.
      seed = seed_embedding_for(user, agent, subject, scope)
      return [] unless seed

      adapter  = ActiveAI.vector_store_adapter
      results  = adapter.query(embedding: seed, limit: 50, filter: { tier: "cold" })
      memories = load_memories_from_vector_results(results)
      ranked   = rank_with_scores(memories, results, user, agent, subject, scope, weight: 1.0)
      selected = select_within_budget(ranked, token_budget)
      touch_access(selected) if selected.any?
      selected
    end

    def self.hybrid_recall(user, agent, subject, scope, token_budget)
      # Step 1: warm key lookup
      warm_relation = build_relation(ActiveAIMemory.warm, user, agent, subject, scope)
      warm_records  = rank(warm_relation.to_a, user, agent, subject, scope)

      # Step 2: cold vector search seeded by warm embeddings
      cold_records = []
      if (seed = seed_embedding_for_records(warm_records))
        adapter = ActiveAI.vector_store_adapter
        results = adapter.query(embedding: seed, limit: 50, filter: { tier: "cold" })
        cold_memories = load_memories_from_vector_results(results)

        # Exclude any IDs already in warm results
        warm_ids = warm_records.map(&:id).to_set
        cold_memories.reject! { |memory| warm_ids.include?(memory.id) }

        cold_records = rank_with_scores(cold_memories, results, user, agent, subject, scope, weight: 1.0)
      end

      # Step 3: merge — warm scores weighted 1.2x, then sort descending by weighted score
      warm_scored = warm_records.map { |memory| [specificity_score(memory, user, agent, subject, scope) * 1.2, memory] }
      cold_scored = cold_records.map { |memory| [specificity_score(memory, user, agent, subject, scope) * 1.0, memory] }

      merged = (warm_scored + cold_scored)
        .sort_by { |score, memory| [-score, -(memory.last_accessed_at&.to_i || 0)] }
        .map(&:last)

      selected = select_within_budget(merged, token_budget)
      touch_access(selected) if selected.any?
      selected
    end

    # --- Relation builders ---

    def self.build_relation(base, user, agent, subject, scope)
      relation = base
      relation = relation.where(user_type:    user.class.name, user_id: user.id) if user
      relation = relation.where(agent_class:  agent.name)                         if agent
      relation = relation.where(subject_type: subject.class.name, subject_id: subject.id) if subject
      relation = relation.where(scope:        scope)                               if scope
      relation.order(last_accessed_at: :desc)
    end

    # --- Scoring ---

    def self.rank(memories, user, agent, subject, scope)
      memories
        .sort_by { |memory| [-specificity_score(memory, user, agent, subject, scope), -(memory.last_accessed_at&.to_i || 0)] }
    end

    def self.rank_with_scores(memories, vector_results, user, agent, subject, scope, weight:)
      vector_score_by_memory_id = vector_results.each_with_object({}) { |vector_result, score_index| score_index[vector_result[:memory_id]] = vector_result[:score] }
      memories.sort_by do |memory|
        specificity  = specificity_score(memory, user, agent, subject, scope)
        vector_score = (vector_score_by_memory_id[memory.id] || 0.0) * weight
        [-(specificity + vector_score), -(memory.last_accessed_at&.to_i || 0)]
      end
    end

    def self.specificity_score(memory, user, agent, subject, scope)
      score = 0
      score += 1 if user    && memory.user_type    == user.class.name && memory.user_id    == user.id
      score += 1 if agent   && memory.agent_class  == agent.name
      score += 1 if subject && memory.subject_type == subject.class.name && memory.subject_id == subject.id
      score += 1 if scope   && memory.scope        == scope
      score
    end

    # --- Budget enforcement ---

    def self.select_within_budget(ranked, token_budget)
      selected = []
      used     = 0
      first    = true

      ranked.each do |memory|
        tokens = memory.token_estimate || estimate_tokens(memory.summary)
        if first
          # Always include the highest-specificity memory even if it exceeds the budget.
          selected << memory
          used  += tokens
          first  = false
        elsif used + tokens <= token_budget
          selected << memory
          used += tokens
        end
      end

      selected
    end

    # --- Side effects ---

    def self.touch_access(memories)
      ids = memories.map(&:id)
      ActiveAIMemory.where(id: ids).update_all(
        access_count:     ActiveAIMemory.arel_table[:access_count] + 1,
        last_accessed_at: Time.current
      )
    end

    # --- Vector seed helpers ---

    # Returns a seed embedding by finding an existing embedding for matching warm memories.
    def self.seed_embedding_for(user, agent, subject, scope)
      relation  = build_relation(ActiveAIMemory.warm, user, agent, subject, scope)
      memory_ids = relation.limit(5).pluck(:id)
      return nil if memory_ids.empty?

      embedding_record = ActiveAIMemoryEmbedding
        .where(memory_id: memory_ids, vector_store: "pgvector")
        .where.not(embedding: nil)
        .first

      embedding_record&.embedding
    end

    # Returns a seed embedding from an already-loaded set of warm memory records.
    def self.seed_embedding_for_records(warm_records)
      return nil if warm_records.empty?

      embedding_record = ActiveAIMemoryEmbedding
        .where(memory_id: warm_records.map(&:id), vector_store: "pgvector")
        .where.not(embedding: nil)
        .first

      embedding_record&.embedding
    end

    # --- Vector result loading ---

    def self.load_memories_from_vector_results(results)
      return [] if results.empty?

      ids = results.map { |vector_result| vector_result[:memory_id] }
      memories_by_id = ActiveAIMemory.where(id: ids).index_by(&:id)
      ids.filter_map { |id| memories_by_id[id] }
    end

    # --- Attribute helpers ---

    def self.build_lookup_attrs(user, agent, subject, scope)
      {
        user_type:    user&.class&.name,
        user_id:      user&.id,
        agent_class:  agent&.name,
        subject_type: subject&.class&.name,
        subject_id:   subject&.id,
        scope:        scope
      }
    end

    def self.estimate_tokens(summary)
      summary.to_json.length / 4
    end
  end
end
