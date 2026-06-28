module ActiveAI
  class LogSubscriber < ActiveSupport::LogSubscriber
    # active_ai.agent.complete — full agent turn with messages, response, token usage
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

    # active_ai.orchestrator.route — routing decision with dispatched agents/workflows
    def orchestrator_route(event)
      p          = event.payload
      usage      = p[:usage] || {}
      dispatched = (p[:dispatched_to] || []).join(', ')
      dispatched = dispatched.present? ? dispatched : "none"
      info "  #{color('ActiveAI orchestrator', MAGENTA, bold: true)} #{p[:orchestrator_class]} #{p[:model]}" \
           " (#{event.duration.round(1)}ms |" \
           " dispatched=#{dispatched} | in=#{usage[:input_tokens] || '?'} out=#{usage[:output_tokens] || '?'})"
    end

    # active_ai.orchestrator.dispatch — individual dispatch to an agent or workflow
    def orchestrator_dispatch(event)
      p = event.payload
      info "  #{color('ActiveAI dispatch', MAGENTA, bold: true)} #{p[:source_class]} → #{p[:step_name]}" \
           " (#{event.duration.round(1)}ms)"
    end

    # active_ai.workflow.run — full workflow execution
    def workflow_run(event)
      p = event.payload
      caller = p[:caller_type] ? " [called by #{p[:caller_type]}:#{p[:caller_name]}]" : ""
      info "  #{color('ActiveAI workflow', YELLOW, bold: true)} #{p[:workflow_class]}" \
           " (#{event.duration.round(1)}ms)#{caller}"
    end

    # active_ai.workflow.step — single step within a workflow
    def workflow_step(event)
      p     = event.payload
      usage = p[:usage] || {}
      info "  #{color('ActiveAI step', GREEN, bold: true)} #{p[:source_class]} → #{p[:step_name]}" \
           " (#{event.duration.round(1)}ms |" \
           " in=#{usage[:input_tokens] || '?'} out=#{usage[:output_tokens] || '?'})"
    end

    # active_ai.workflow.parallel_step — concurrent step batch
    def workflow_parallel_step(event)
      p = event.payload
      info "  #{color('ActiveAI parallel', YELLOW, bold: true)} #{p[:workflow_class]}" \
           " #{p[:count]} steps [#{(p[:steps] || []).join(', ')}]" \
           " (#{event.duration.round(1)}ms)"
    end

    # active_ai.tool.call — individual tool invocation
    def tool_call(event)
      p      = event.payload
      caller = p[:caller_type] ? " [#{p[:caller_type]}:#{p[:caller_name]}]" : ""
      info "  #{color('ActiveAI tool', MAGENTA, bold: true)} #{p[:tool_name]}" \
           " (#{event.duration.round(1)}ms)#{caller}"
    end

    # active_ai.skill.resolve — skill content resolved for inclusion in a prompt
    def skill_resolve(event)
      p = event.payload
      info "  #{color('ActiveAI skill', WHITE, bold: true)} #{p[:skill_name]}" \
           " (#{p[:content_length]} chars)"
    end

    # active_ai.agent.stream — lower-level stream loop (fires inside agent.complete)
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
