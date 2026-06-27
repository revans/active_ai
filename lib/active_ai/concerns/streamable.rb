module ActiveAI
  module Concerns
    module Streamable
      extend ActiveSupport::Concern

      included do
        include ActionController::Live
      end

      private

      def stream_agent(agent, &after_stream)
        response.headers["Content-Type"]      = "text/event-stream"
        response.headers["Cache-Control"]     = "no-cache"
        response.headers["X-Accel-Buffering"] = "no"

        full_response = String.new

        # Rescue only here — a disconnect during chunk writes is fine,
        # we still have the accumulated text and must save it.
        begin
          agent.stream do |event|
            if event.is_a?(Hash)
              response.stream.write("data: #{JSON.generate(event)}\n\n")
            else
              full_response << event
              response.stream.write("data: #{JSON.generate(chunk: event)}\n\n")
            end
          end
        rescue ActionController::Live::ClientDisconnected
          # Client disconnected mid-stream — keep full_response and fall through
        end

        # Always run: persist message, create AgentCall, write stats event.
        after_stream&.call(full_response)

        # Memory hook: no-op by default; controllers override to enqueue PersistJob.
        after_stream_memory_persist(agent, full_response)

        full_response
      rescue => stream_error
        Rails.logger.error("stream_conversation failed: #{stream_error.class} #{stream_error.message}")
        response.stream.write("data: #{JSON.generate(error: stream_error_message(stream_error))}\n\n") rescue nil
        full_response
      ensure
        # Must run even if after_stream raised — client hangs otherwise.
        response.stream.write("data: [DONE]\n\n") rescue nil
        response.stream.close
      end

      # Hook for controllers that want to persist memory after a streaming session ends.
      # No-op by default — controllers that want memory override this method and
      # enqueue ActiveAI::Memory::PersistJob with the appropriate context.
      #
      # Never perform memory operations inline here — this must be async.
      def after_stream_memory_persist(agent, full_response)
        # no-op by default
      end

      def stream_error_message(error)
        if error.is_a?(ActiveAI::ProviderError)
          # Extract the inner API message from the provider error body
          error.message.match(/message: "([^"]+)"/)&.captures&.first ||
            error.message.match(/"message":\s*"([^"]+)"/)&.captures&.first ||
            "Provider error. Please try again."
        else
          "Something went wrong. Please try again."
        end
      end
    end
  end
end
