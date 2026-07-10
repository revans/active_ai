# Mirrors lib/generators/active_ai/memory/templates/jobs/active_ai_memory_embed_job.rb.tt
# — this is what a host app gets from `rails generate active_ai:memory:install`.
# ActiveAI::Memory::Store#persist enqueues this job unconditionally whenever
# async: true (the default), so the dummy app needs a real copy for that path
# to be testable instead of raising NameError.
class ActiveAIMemoryEmbedJob < ApplicationJob
  queue_as :active_ai_memory

  def perform(memory_id)
    memory = ActiveAIMemory.find_by(id: memory_id)
    return unless memory

    embed_agent = ActiveAIMemoryEmbedAgent.new(summary: memory.summary)
    raw         = embed_agent.complete
    parsed      = JSON.parse(raw)
    text        = parsed["embedding_text"]

    vector = embedding_vector(text)
    return unless vector

    store = ActiveAI.vector_store_adapter
    store.upsert(
      memory_id: memory.id,
      embedding:  vector,
      metadata:   { agent_class: memory.agent_class, tier: memory.tier }
    )

    ActiveAIMemoryEmbedding.find_or_initialize_by(
      memory_id:    memory.id,
      vector_store: "pgvector"
    ).update!(vector_id: memory.id.to_s, embedded_at: Time.current)
  rescue JSON::ParserError => e
    Rails.logger.error("[ActiveAIMemoryEmbedJob] JSON parse error for memory #{memory_id}: #{e.message}")
  rescue StandardError => e
    Rails.logger.error("[ActiveAIMemoryEmbedJob] Error embedding memory #{memory_id}: #{e.message}")
    raise
  end

  private

  def embedding_vector(text)
    # Stub — replace with a real provider embedding call for production.
    Array.new(1536, 0.0)
  end
end
