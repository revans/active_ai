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
           " in=#{usage[:input_tokens] || '?'} out=#{usage[:output_tokens] || '?'}#{tool_note})#{caller}#{traced(p)}"
    end

    # orchestrator_route.active_ai — routing decision with dispatched agents/workflows
    def orchestrator_route(event)
      p          = event.payload
      usage      = p[:usage] || {}
      dispatched = (p[:dispatched_to] || []).join(', ')
      dispatched = dispatched.present? ? dispatched : "none"
      info "  #{color('ActiveAI orchestrator', MAGENTA, bold: true)} #{p[:orchestrator_class]} #{p[:model]}" \
           " (#{event.duration.round(1)}ms |" \
           " dispatched=#{dispatched} | in=#{usage[:input_tokens] || '?'} out=#{usage[:output_tokens] || '?'})#{traced(p)}"
    end

    # orchestrator_dispatch.active_ai — individual dispatch to an agent or workflow
    def orchestrator_dispatch(event)
      p = event.payload
      info "  #{color('ActiveAI dispatch', MAGENTA, bold: true)} #{p[:source_class]} → #{p[:step_name]}" \
           " (#{event.duration.round(1)}ms)#{traced(p)}"
    end

    # workflow_run.active_ai — full workflow execution
    def workflow_run(event)
      p = event.payload
      caller = p[:caller_type] ? " [called by #{p[:caller_type]}:#{p[:caller_name]}]" : ""
      info "  #{color('ActiveAI workflow', YELLOW, bold: true)} #{p[:workflow_class]}" \
           " (#{event.duration.round(1)}ms)#{caller}#{traced(p)}"
    end

    # workflow_step.active_ai — single step within a workflow
    def workflow_step(event)
      p     = event.payload
      usage = p[:usage] || {}
      info "  #{color('ActiveAI step', GREEN, bold: true)} #{p[:source_class]} → #{p[:step_name]}" \
           " (#{event.duration.round(1)}ms |" \
           " in=#{usage[:input_tokens] || '?'} out=#{usage[:output_tokens] || '?'})#{traced(p)}"
    end

    # workflow_parallel_step.active_ai — concurrent step batch
    def workflow_parallel_step(event)
      p = event.payload
      info "  #{color('ActiveAI parallel', YELLOW, bold: true)} #{p[:workflow_class]}" \
           " #{p[:count]} steps [#{(p[:steps] || []).join(', ')}]" \
           " (#{event.duration.round(1)}ms)#{traced(p)}"
    end

    # tool_call.active_ai — individual tool invocation
    def tool_call(event)
      p      = event.payload
      caller = p[:caller_type] ? " [#{p[:caller_type]}:#{p[:caller_name]}]" : ""
      info "  #{color('ActiveAI tool', MAGENTA, bold: true)} #{p[:tool_name]}" \
           " (#{event.duration.round(1)}ms)#{caller}#{traced(p)}"
    end

    # skill_resolve.active_ai — skill content resolved for inclusion in a prompt
    def skill_resolve(event)
      p = event.payload
      info "  #{color('ActiveAI skill', WHITE, bold: true)} #{p[:skill_name]}" \
           " (#{p[:content_length]} chars)#{traced(p)}"
    end

    # agent_stream.active_ai — lower-level stream loop (fires inside agent_complete.active_ai)
    def agent_stream(event)
      p     = event.payload
      usage = p[:usage] || {}
      tools = p[:tool_calls] || []
      tool_note = tools.any? ? " | tools=#{tools.map { |t| t[:name] }.join(',')}" : ""
      debug "  #{color('ActiveAI stream', CYAN, bold: false)} #{p[:agent_class]} #{p[:model]}" \
            " (#{event.duration.round(1)}ms |" \
            " in=#{usage[:input_tokens] || '?'} out=#{usage[:output_tokens] || '?'}#{tool_note})#{traced(p)}"
    end

    # agent_turn.active_ai — one provider call inside an agent loop (never logs the text)
    def agent_turn(event)
      p     = event.payload
      tools = (p[:tool_calls] || []).map { |t| t[:name] }
      tool_note = tools.any? ? " | tools=#{tools.join(',')}" : ""
      debug "  #{color('ActiveAI turn', CYAN, bold: false)} #{p[:agent_class]} ##{p[:turn]} #{p[:model]}" \
            " (finish=#{p[:finish_reason] || '?'}#{tool_note})#{traced(p)}"
    end

    # agent_usage.active_ai — tokens summed over every turn of one agent run
    def agent_usage(event)
      p     = event.payload
      usage = p[:usage] || {}
      info "  #{color('ActiveAI usage', CYAN, bold: true)} #{p[:agent_class]} #{p[:model]}" \
           " (turns=#{p[:turns]} in=#{usage[:input_tokens] || '?'} out=#{usage[:output_tokens] || '?'}" \
           " cache_read=#{usage[:cache_read_tokens] || 0}#{p[:completed] ? '' : ' | incomplete'})#{traced(p)}"
    end

    # command_call.active_ai — a typed chat command dispatched
    def command_call(event)
      p      = event.payload
      caller = p[:caller_type] ? " [#{p[:caller_type]}:#{p[:caller_name]}]" : ""
      info "  #{color('ActiveAI command', MAGENTA, bold: true)} #{p[:command_name]}" \
           " (#{event.duration.round(1)}ms)#{caller}#{traced(p)}"
    end

    # record_query.active_ai — what RecordQuery read (never the rows)
    def record_query(event)
      p      = event.payload
      target = [p[:root_class], p[:root_id], p[:association]].compact.join(" ")
      scopes = Array(p[:scopes]).map { |s| s.is_a?(Hash) ? (s[:name] || s["name"]) : s }
      detail = case p[:outcome]
               when :read    then "rows=#{p[:returned]}#{p[:truncated] ? " of #{p[:total]}" : ''}"
               when :catalog then "catalog"
               when :refused then "refused: #{p[:reason]}"
               else p[:exception]&.first || "?"
               end
      scope_note = scopes.any? ? " | scopes=#{scopes.join(',')}" : ""
      info "  #{color('ActiveAI query', MAGENTA, bold: true)} #{target}" \
           " (#{event.duration.round(1)}ms | #{detail}#{scope_note})#{traced(p)}"
    end

    # agent_request.active_ai — the prompt about to be sent (never logs its content; the event carries it)
    def agent_request(event)
      p = event.payload
      debug "  #{color('ActiveAI request', CYAN, bold: false)} #{p[:agent_class]} ##{p[:turn]} #{p[:model]}" \
            " (messages=#{Array(p[:messages]).size} tools=#{Array(p[:tools]).size})#{traced(p)}"
    end

    private

    # The ids that tie this line to its prompt and answer: grep the run, then match a
    # provider call's request and turn lines by span.
    def traced(payload)
      ids = { run: payload[:run_id], span: payload[:span_id], request: payload[:request_id], job: payload[:job_id] }.compact
      ids.empty? ? "" : " #{ids.map { |key, id| "#{key}=#{id}" }.join(' ')}"
    end
  end
end

ActiveAI::LogSubscriber.attach_to :active_ai
