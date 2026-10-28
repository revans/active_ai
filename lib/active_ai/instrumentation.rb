require "securerandom"
require "active_support/isolated_execution_state"

module ActiveAI
  # Who called what, and which run it belongs to — the ids every event carries so a
  # prompt, the model's answer and every log line around them can be tied together.
  #
  # - run_id:         one per top-level ActiveAI call; everything nested shares it.
  # - span_id:        one per component invocation (agent, tool, workflow, command)
  #                   and per provider call; parent_span_id makes the tree.
  # - request_id /    the Rails request or Active Job the run happened in, when there
  #   job_id:         is one, so AI log lines filter alongside the app's own.
  #
  # Ids are ActiveAI's own and minted before anything is sent, so a line logged before
  # a provider call — or for a call that never got an answer — still has them. The
  # provider's own id is recorded beside them when there is one; it is never the key.
  #
  # State lives in ActiveSupport::IsolatedExecutionState, so it follows the app's
  # isolation level (thread or fiber).
  #
  #   ActiveAI::Instrumentation.with_caller(type: :job, name: "MyJob") do
  #     # current_caller => { type: :job, name: "MyJob", span_id: "...", parent_span_id: nil }
  #   end
  module Instrumentation
    STACK_KEY = :active_ai_caller_stack
    RUN_KEY   = :active_ai_run

    def self.caller_stack
      ActiveSupport::IsolatedExecutionState[STACK_KEY] ||= []
    end

    def self.current_caller
      caller_stack.last
    end

    # { run_id:, request_id:, job_id: } for the run in progress, or nil outside one.
    def self.current_run
      ActiveSupport::IsolatedExecutionState[RUN_KEY]
    end

    def self.new_id
      SecureRandom.respond_to?(:uuid_v7) ? SecureRandom.uuid_v7 : SecureRandom.uuid
    end

    # Runs the block inside a run, starting one if none is in progress. Pass run_id: to
    # use an id of your own for a new run; a nested call keeps the outer run.
    def self.with_run(run_id: nil)
      return yield if current_run

      ActiveSupport::IsolatedExecutionState[RUN_KEY] = { run_id: run_id || new_id }.merge(ambient_ids)
      begin
        yield
      ensure
        ActiveSupport::IsolatedExecutionState.delete(RUN_KEY)
      end
    end

    # Pushes a span for the block and yields it.
    def self.with_caller(type:, name:)
      span = { type: type, name: name, span_id: new_id, parent_span_id: current_caller&.dig(:span_id) }
      with_run do
        caller_stack.push(span)
        begin
          yield span
        ensure
          caller_stack.pop
        end
      end
    end

    # A span for something that is not a caller of anything — one provider call — so
    # its request and turn events can share an id without becoming anyone's parent.
    def self.leaf_span(type:, name:)
      { type: type, name: name, span_id: new_id, parent_span_id: current_caller&.dig(:span_id) }
    end

    # Fires event with the run and span ids merged into payload.
    #
    #   as:   { type:, name: } — open a span for this component around the block
    #   span: a span from leaf_span — the event belongs to that span
    #   neither — the event belongs to the current span
    #
    # caller_type/caller_name always name the span that was current before this one.
    def self.instrument(event, payload = {}, as: nil, span: nil, &block)
      with_run do
        parent = current_caller
        ids    = { caller_type: parent&.dig(:type), caller_name: parent&.dig(:name) }.merge(current_run)

        if as
          with_caller(**as) do |own|
            fire(event, payload.merge(ids, span_ids(own)), &block)
          end
        else
          fire(event, payload.merge(ids, span_ids(span || parent)), &block)
        end
      end
    end

    # A new Thread starts with no run and an empty stack. Capture before spawning and
    # run the thread's work inside restore, or everything in it starts a run of its own.
    #
    #   snapshot = ActiveAI::Instrumentation.capture
    #   Thread.new { ActiveAI::Instrumentation.restore(snapshot) { step(...) } }
    def self.capture
      { stack: caller_stack.dup, run: current_run }
    end

    def self.restore(snapshot)
      previous = [ActiveSupport::IsolatedExecutionState[STACK_KEY], current_run]
      ActiveSupport::IsolatedExecutionState[STACK_KEY] = snapshot[:stack].dup
      ActiveSupport::IsolatedExecutionState[RUN_KEY]   = snapshot[:run]
      yield
    ensure
      ActiveSupport::IsolatedExecutionState[STACK_KEY], ActiveSupport::IsolatedExecutionState[RUN_KEY] = previous
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

    def self.fire(event, payload, &block)
      return ActiveSupport::Notifications.instrument(event, payload) unless block

      ActiveSupport::Notifications.instrument(event, payload, &block)
    end
    private_class_method :fire

    def self.span_ids(span)
      { span_id: span&.dig(:span_id), parent_span_id: span&.dig(:parent_span_id) }
    end
    private_class_method :span_ids

    # The Rails request or Active Job this run is happening in, from the execution
    # context Action Controller and Active Job set.
    def self.ambient_ids
      return {} unless defined?(ActiveSupport::ExecutionContext)

      context    = ActiveSupport::ExecutionContext.to_h
      controller = context[:controller]
      job        = context[:job]
      {
        request_id: controller.respond_to?(:request) ? controller.request&.request_id : nil,
        job_id:     job.respond_to?(:job_id) ? job.job_id : nil
      }.compact
    end
    private_class_method :ambient_ids
  end
end
