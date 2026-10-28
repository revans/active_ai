module ActiveAI
  # Thread-local caller stack for cross-component instrumentation context.
  #
  # Think of it like a call stack for the AI layer: when an orchestrator calls an agent,
  # which calls a tool, the stack records who called what. Each notification payload
  # reads the top of the stack to answer "who triggered me?"
  #
  # Usage:
  #   ActiveAI::Instrumentation.with_caller(type: :agent, name: "WritingAgent") do
  #     # inside here, current_caller returns { type: :agent, name: "WritingAgent" }
  #   end
  #
  module Instrumentation
    def self.caller_stack
      Thread.current[:active_ai_caller_stack] ||= []
    end

    def self.current_caller
      caller_stack.last
    end

    def self.with_caller(type:, name:)
      caller_stack.push({ type: type, name: name })
      yield
    ensure
      caller_stack.pop
    end

    # A new Thread starts with an empty stack. Capture the stack before spawning and
    # run the thread's work inside with_stack, or everything in it reports no caller.
    #
    #   stack = ActiveAI::Instrumentation.caller_stack.dup
    #   Thread.new { ActiveAI::Instrumentation.with_stack(stack) { step(...) } }
    def self.with_stack(stack)
      previous = Thread.current[:active_ai_caller_stack]
      Thread.current[:active_ai_caller_stack] = stack.dup
      yield
    ensure
      Thread.current[:active_ai_caller_stack] = previous
    end

    # Instruments the method a subclass overrides — Tool#call, Workflow#run,
    # Command#call — however it is invoked. Called from the base class's inherited
    # hook, so every subclass at every depth gets its own wrapper; only the outermost
    # one fires, so a subclass calling super is still one event.
    #
    # The block runs on the instance with (args, kwargs, invoke) and must call
    # invoke to run the real method.
    def self.instrument_override(subclass, method_name, &wrapper)
      flag = :"@_active_ai_instrumenting_#{method_name}"

      subclass.prepend(Module.new do
        define_method(method_name) do |*args, **kwargs, &block|
          return super(*args, **kwargs, &block) if instance_variable_get(flag)

          instance_variable_set(flag, true)
          begin
            instance_exec(args, kwargs, -> { super(*args, **kwargs, &block) }, &wrapper)
          ensure
            instance_variable_set(flag, false)
          end
        end
      end)
    end
  end
end
