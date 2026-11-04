module ActiveAI
  module Memory
    module VectorStore
      # Pgvector adapter — stores and queries embeddings via the active_ai_memory_embeddings table.
      #
      # Uses the neighbor gem's nearest_neighbors scope (backed by pgvector's HNSW cosine index)
      # rather than raw SQL, so the query planner can use the index we created at migration time.
      #
      # The sqlite? guard is kept so this adapter can be loaded in a mixed environment where
      # Solid Stack still runs on SQLite — it simply no-ops those operations.
      class Pgvector < Base
        def name = "pgvector"

        # Upserts an embedding for the given memory_id.
        # Returns the ActiveAIMemoryEmbedding record's id as the vector_id.
        def upsert(memory_id:, embedding:, metadata: {})
          return "stub-#{memory_id}" if sqlite?

          record = record_for(memory_id)
          record.embedding   = embedding
          record.embedded_at = Time.current
          record.save!
          record.id.to_s
        end

        # Finds memories whose embeddings are cosine-nearest to the query vector.
        # Returns array of { memory_id:, score: } hashes, ordered by similarity descending.
        # score is 1 - cosine_distance, so 1.0 = identical, 0.0 = orthogonal.
        def query(embedding:, limit: 10, filter: {})
          return [] if sqlite?

          scope = ActiveAIMemoryEmbedding
            .nearest_neighbors(:embedding, embedding, distance: "cosine")
            .limit(limit)

          scope = scope.joins(:memory).where(active_ai_memories: filter) if filter.any?

          scope.map do |record|
            { memory_id: record.memory_id, score: 1.0 - record.neighbor_distance }
          end
        end

        # Removes a memory's embedding from the store.
        def delete(memory_id:)
          return if sqlite?

          ActiveAIMemoryEmbedding.where(memory_id: memory_id, vector_store: "pgvector").delete_all
        end

        private

        # The row for a memory, ready to save. vector_id is required by the model, and a new row has none (the row's own id
        # does not exist yet), so it starts as the memory's id, which is what the embed job template also records.
        def record_for(memory_id)
          ActiveAIMemoryEmbedding.find_or_initialize_by(memory_id: memory_id, vector_store: "pgvector").tap do |record|
            record.vector_id = memory_id.to_s if record.vector_id.blank?
          end
        end

        def sqlite?
          ActiveRecord::Base.connection.adapter_name.downcase.include?("sqlite")
        end
      end
    end
  end
end
