module ActiveAI
  class LogSubscriber < ActiveSupport::LogSubscriber
    # agent_complete.active_ai — full agent turn with messages, response, token usage
    def agent_complete(event)
      p       = event.payload
      usage   = p[:usage] || {}
      tools   = p[:tool_calls] || []
      caller  = p[:caller_type] ? " [called by #{p[:caller_type]}:#{p[:caller_name]}]" : ""
      tool_note = tools.any? ? " | tools=#{tools.map { |t| t[:name] }.join(',')}" : ""
      info "  #{color('ActiveAI agent', CYAN, bold: true)} #{p[:agent_class]} #{p[:model]}" \
           " (#{event.duration.round(1)}ms |" \
           " in=#{usage[:input_tokens] || '?'} out=#{usage[:output_tokens] || '?'}#{tool_note})#{caller}"
    end

    # orchestrator_route.active_ai — routing decision with dispatched agents/workflows
    def orchestrator_route(event)
      p          = event.payload
      usage      = p[:usage] || {}
      dispatched = (p[:dispatched_to] || []).join(', ')
      dispatched = dispatched.present? ? dispatched : "none"
      info "  #{color('ActiveAI orchestrator', MAGENTA, bold: true)} #{p[:orchestrator_class]} #{p[:model]}" \
           " (#{event.duration.round(1)}ms |" \
           " dispatched=#{dispatched} | in=#{usage[:input_tokens] || '?'} out=#{usage[:output_tokens] || '?'})"
    end

    # orchestrator_dispatch.active_ai — individual dispatch to an agent or workflow
    def orchestrator_dispatch(event)
      p = event.payload
      info "  #{color('ActiveAI dispatch', MAGENTA, bold: true)} #{p[:source_class]} → #{p[:step_name]}" \
           " (#{event.duration.round(1)}ms)"
    end

    # workflow_run.active_ai — full workflow execution
    def workflow_run(event)
      p = event.payload
      caller = p[:caller_type] ? " [called by #{p[:caller_type]}:#{p[:caller_name]}]" : ""
      info "  #{color('ActiveAI workflow', YELLOW, bold: true)} #{p[:workflow_class]}" \
           " (#{event.duration.round(1)}ms)#{caller}"
    end

    # workflow_step.active_ai — single step within a workflow
    def workflow_step(event)
      p     = event.payload
      usage = p[:usage] || {}
      info "  #{color('ActiveAI step', GREEN, bold: true)} #{p[:source_class]} → #{p[:step_name]}" \
           " (#{event.duration.round(1)}ms |" \
           " in=#{usage[:input_tokens] || '?'} out=#{usage[:output_tokens] || '?'})"
    end

    # workflow_parallel_step.active_ai — concurrent step batch
    def workflow_parallel_step(event)
      p = event.payload
      info "  #{color('ActiveAI parallel', YELLOW, bold: true)} #{p[:workflow_class]}" \
           " #{p[:count]} steps [#{(p[:steps] || []).join(', ')}]" \
           " (#{event.duration.round(1)}ms)"
    end

    # tool_call.active_ai — individual tool invocation
    def tool_call(event)
      p      = event.payload
      caller = p[:caller_type] ? " [#{p[:caller_type]}:#{p[:caller_name]}]" : ""
      info "  #{color('ActiveAI tool', MAGENTA, bold: true)} #{p[:tool_name]}" \
           " (#{event.duration.round(1)}ms)#{caller}"
    end

    # skill_resolve.active_ai — skill content resolved for inclusion in a prompt
    def skill_resolve(event)
      p = event.payload
      info "  #{color('ActiveAI skill', WHITE, bold: true)} #{p[:skill_name]}" \
           " (#{p[:content_length]} chars)"
    end

    # agent_stream.active_ai — lower-level stream loop (fires inside agent_complete.active_ai)
    def agent_stream(event)
      p     = event.payload
      usage = p[:usage] || {}
      tools = p[:tool_calls] || []
      tool_note = tools.any? ? " | tools=#{tools.map { |t| t[:name] }.join(',')}" : ""
      debug "  #{color('ActiveAI stream', CYAN, bold: false)} #{p[:agent_class]} #{p[:model]}" \
            " (#{event.duration.round(1)}ms |" \
            " in=#{usage[:input_tokens] || '?'} out=#{usage[:output_tokens] || '?'}#{tool_note})"
    end

  end
end

ActiveAI::LogSubscriber.attach_to :active_ai
