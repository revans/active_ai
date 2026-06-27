module ActiveAI
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
  end
end
