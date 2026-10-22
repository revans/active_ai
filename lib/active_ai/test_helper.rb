module ActiveAI
  # Test helpers for apps using ActiveAI: stubs (no provider calls), Response assertions, tool-call and
  # system-prompt assertions, and a build_ai_response factory. A table of all of them is in docs/testing.md.
  module TestHelper
    # Stubs a specific agent instance to yield a fixed response string.
    # Bypasses the provider entirely — use when you only care about what the
    # agent does with a response, not the provider interaction itself.
    #
    #   agent = WritingAgent.new(system: "...", message: "hi")
    #   stub_ai_response(agent, response: "Here is your draft.")
    #   assert_equal "Here is your draft.", agent.complete
    def stub_ai_response(agent, response:)
      agent.define_singleton_method(:stream) do |&block|
        response.each_char { |c| block.call(c) }
      end
    end

    # Stubs the provider for an agent instance, simulating one or two turns
    # of the agentic loop without making real API calls.
    #
    # Simple (no tool calls):
    #   stub_provider(agent, response: "the answer")
    #
    # With a tool call turn (provider requests a tool, then responds):
    #   stub_provider(agent, response: "all done",
    #                        tool_calls: [{ id: "t1", name: "ping", input: { "input" => "hi" } }])
    #
    # Only affects the stubbed instance, not the class.
    def stub_provider(agent, response: "", tool_calls: [])
      call_count = 0
      agent.define_singleton_method(:provider_instance) do
        call_count += 1
        prov = Object.new
        if tool_calls.any? && call_count == 1
          prov.define_singleton_method(:stream)                 { |_params, &block| }
          prov.define_singleton_method(:last_usage)             { nil }
          prov.define_singleton_method(:last_tool_calls)        { tool_calls }
          prov.define_singleton_method(:last_assistant_content) do
            tool_calls.map { |tc| { type: "tool_use", id: tc[:id], name: tc[:name], input: tc[:input] } }
          end
        else
          prov.define_singleton_method(:stream)                 { |_params, &block| block.call(response) }
          prov.define_singleton_method(:last_usage)             { nil }
          prov.define_singleton_method(:last_tool_calls)        { [] }
          prov.define_singleton_method(:last_assistant_content) { [] }
        end
        # Default Anthropic-format message builders — mirrors Provider::Base defaults.
        # These exist so the stub works after base.rb was updated to delegate to the provider.
        prov.define_singleton_method(:format_assistant_turn) { |content, _tc| { role: "assistant", content: content } }
        prov.define_singleton_method(:format_tool_result_messages) { |results| [{ role: "user", content: results }] }
        prov
      end
    end

    # Asserts that the given tool was called during the last stream invocation.
    #
    #   agent.stream { }
    #   assert_ai_tool_called agent, :web_search
    def assert_ai_tool_called(agent, tool_name)
      assert agent.last_tool_call_results.any? { |r| r[:name] == tool_name.to_s },
             "Expected #{tool_name} to be called, but it wasn't. " \
             "Tools called: #{agent.last_tool_call_results.map { |r| r[:name] }.inspect}"
    end

    # Asserts that the given tool was NOT called during the last stream invocation.
    #
    #   agent.stream { }
    #   refute_ai_tool_called agent, :web_search
    def refute_ai_tool_called(agent, tool_name)
      refute agent.last_tool_call_results.any? { |r| r[:name] == tool_name.to_s },
             "Expected #{tool_name} NOT to be called, but it was."
    end

    # Asserts that no tools were invoked during the last stream call.
    #
    #   agent.stream { }
    #   assert_no_ai_tools_called agent
    def assert_no_ai_tools_called(agent)
      assert_empty agent.last_tool_call_results,
                   "Expected no tools to be called, but got: " \
                   "#{agent.last_tool_call_results.map { |r| r[:name] }.inspect}"
    end

    # Asserts that the agent's resolved system prompt (to_canonical_params[:system])
    # includes the given substring.
    #
    #   assert_agent_system_includes agent, "Historical context"
    def assert_agent_system_includes(agent, text, msg = nil)
      system_prompt = agent.to_canonical_params[:system]
      assert_includes system_prompt, text,
                      msg || "Expected system prompt to include #{text.inspect}\n" \
                             "System prompt was: #{system_prompt.inspect}"
    end

    # Asserts that the agent's resolved system prompt does not include the given substring.
    #
    #   refute_agent_system_includes agent, "Historical context"
    def refute_agent_system_includes(agent, text, msg = nil)
      system_prompt = agent.to_canonical_params[:system]
      refute_includes system_prompt, text,
                      msg || "Expected system prompt NOT to include #{text.inspect}"
    end

    # ── Response assertions ──────────────────────────────────────────────────────
    # For an ActiveAI::Response (what agent.generate returns). Each failure says what the
    # model actually did: why it stopped, who answered, and a peek at the text.

    # Asserts the model finished normally: not cut off, not refused, not stopped for a tool call.
    #
    #   assert_ai_complete agent.generate
    def assert_ai_complete(response, msg = nil)
      assert response.complete?, msg || "Expected a complete response, but #{describe_ai_response(response)}"
    end

    # Asserts the model stopped for the given reason (:complete, :truncated, :tool_use, :refused, :other).
    # Handy for testing how your app handles a cut-off or refused answer.
    #
    #   assert_ai_finish_reason response, :truncated
    def assert_ai_finish_reason(response, expected, msg = nil)
      assert_equal expected, response.finish_reason, msg || "Expected finish_reason #{expected.inspect}, but #{describe_ai_response(response)}"
    end

    # Asserts there is a parsed structured answer (response.data), explaining why not when there is none.
    #
    #   assert_ai_structured agent.generate
    def assert_ai_structured(response, msg = nil)
      assert response.data, msg || "Expected structured data, but #{describe_ai_response(response)}"
    end

    # Asserts the call stayed inside a budget. Any combination of limits; those omitted are not checked.
    #
    #   assert_ai_within response, output_tokens: 400, seconds: 10
    def assert_ai_within(response, output_tokens: nil, total_tokens: nil, seconds: nil)
      usage = response.usage || {}
      if output_tokens
        assert_operator usage[:output_tokens].to_i, :<=, output_tokens, "Used #{usage[:output_tokens]} output tokens (limit #{output_tokens}). #{describe_ai_response(response)}"
      end
      if total_tokens
        total = usage[:input_tokens].to_i + usage[:output_tokens].to_i
        assert_operator total, :<=, total_tokens, "Used #{total} tokens in total (limit #{total_tokens}). #{describe_ai_response(response)}"
      end
      assert_operator response.latency, :<=, seconds, "Took #{response.latency}s (limit #{seconds}s). #{describe_ai_response(response)}" if seconds
    end

    # Asserts who answered: the provider, and optionally the model that actually served the request
    # (a String for an exact match, a Regexp for a pattern).
    #
    #   assert_ai_served_by response, provider: :openai, model: /\Agpt-5/
    def assert_ai_served_by(response, provider:, model: nil)
      assert_equal provider.to_sym, response.provider, "Expected provider #{provider.inspect}, but #{describe_ai_response(response)}"
      return unless model
      matched = model.is_a?(Regexp) ? model.match?(response.model.to_s) : model == response.model
      assert matched, "Expected served model #{model.inspect}, but #{describe_ai_response(response)}"
    end

    # Builds an ActiveAI::Response for testing code that consumes one, without calling a provider.
    # Defaults to a complete answer; override anything.
    #
    #   response = build_ai_response(finish_reason: :truncated, text: "1, 2, 3")
    #   response = build_ai_response(data: { "title" => "Hi" }, text: '{"title":"Hi"}')
    def build_ai_response(text: "ok", finish_reason: :complete, raw_finish_reason: nil, data: nil, data_error: nil, refusal: nil,
                          provider: :test, requested_model: "test-model", model: "test-model", usage: nil, turns: 1,
                          request_id: "req-test", tool_calls: [], latency: 0.01)
      ActiveAI::Response.new(
        text: text, data: data, data_error: data_error, provider: provider, requested_model: requested_model, model: model,
        finish_reason: finish_reason, raw_finish_reason: raw_finish_reason || finish_reason.to_s, refusal: refusal,
        usage: usage || { input_tokens: 10, output_tokens: 5, cache_creation_tokens: 0, cache_read_tokens: 0, reasoning_tokens: nil,
                          stop_reason: raw_finish_reason || finish_reason.to_s, provider_request_id: request_id },
        turns: turns, request_id: request_id, tool_calls: tool_calls, latency: latency
      )
    end

    # Stubs ActiveAI::Memory.recall to return a fixed array of memories.
    #
    # With a block — automatically restores recall when the block exits:
    #   stub_memory_recall(memories: [memory]) do
    #     assert_agent_system_includes agent, "Be concise"
    #   end
    #
    # Without a block — call restore_memory_recall in teardown:
    #   stub_memory_recall(memories: [memory])
    #   # ... test code ...
    #   restore_memory_recall
    def stub_memory_recall(memories: [], &block)
      original = ActiveAI::Memory.method(:recall)
      ActiveAI::Memory.define_singleton_method(:recall) { |**_args| memories }
      if block
        begin
          block.call
        ensure
          ActiveAI::Memory.define_singleton_method(:recall, original)
        end
      else
        @_memory_recall_original = original
      end
    end

    # Restores ActiveAI::Memory.recall after a non-block stub_memory_recall call.
    # Call in teardown if you used stub_memory_recall without a block.
    def restore_memory_recall
      return unless @_memory_recall_original
      ActiveAI::Memory.define_singleton_method(:recall, @_memory_recall_original)
      @_memory_recall_original = nil
    end

    private

    def describe_ai_response(response)
      peek = response.text.to_s.squish.truncate(80)
      [ "finish_reason was #{response.finish_reason.inspect} (provider said #{response.raw_finish_reason.inspect})",
        ("refusal: #{response.refusal.inspect}" if response.refusal.present?),
        ("data_error: #{response.data_error}" if response.data_error.present?),
        "served by #{response.provider}/#{response.model.inspect}",
        "text: #{peek.inspect}" ].compact.join("; ")
    end
  end
end
