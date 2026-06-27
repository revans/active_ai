module ActiveAI
  class LogSubscriber < ActiveSupport::LogSubscriber
    def stream(event)
      usage_data = event.payload[:usage] || {}
      tools      = event.payload[:tool_calls] || []
      tool_note  = tools.any? ? " | tools=#{tools.map { |tool_call| tool_call[:name] }.join(",")}" : ""
      info "  #{color("ActiveAI stream", CYAN, bold: true)} #{event.payload[:model]} " \
           "(#{event.duration.round(1)}ms | " \
           "in=#{usage_data[:input_tokens] || "?"}  out=#{usage_data[:output_tokens] || "?"}#{tool_note})"
    end

    def tool_call(event)
      info "  #{color("ActiveAI tool", MAGENTA, bold: true)} #{event.payload[:tool_name]} " \
           "(#{event.duration.round(1)}ms)"
    end
  end
end

ActiveAI::LogSubscriber.attach_to :active_ai
