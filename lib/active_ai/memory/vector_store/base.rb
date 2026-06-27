module ActiveAI
  module Memory
    module VectorStore
      # Base adapter interface for vector storage backends.
      #
      # Implement all three methods in subclasses.
      # External vector stores (Pinecone, Weaviate) would add new subclasses here.
      class Base
        # Store or update a memory's embedding vector.
        # memory_id: Integer, embedding: Array<Float>, metadata: Hash
        def upsert(memory_id:, embedding:, metadata: {})
          raise NotImplementedError, "#{self.class}#upsert is not implemented"
        end

        # Find similar memories by vector similarity.
        # embedding: Array<Float>, limit: Integer, filter: Hash
        # Returns: Array of { memory_id:, score: } hashes
        def query(embedding:, limit: 10, filter: {})
          raise NotImplementedError, "#{self.class}#query is not implemented"
        end

        # Remove a memory's embedding from the vector store.
        # memory_id: Integer
        def delete(memory_id:)
          raise NotImplementedError, "#{self.class}#delete is not implemented"
        end
      end
    end
  end
end
