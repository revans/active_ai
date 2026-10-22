module ActiveAI
  module Concerns
    module Streamable
      extend ActiveSupport::Concern

      included do
        include ActionController::Live
      end

      # close: true (default) preserves the original single-turn contract —
      # writes the terminal [DONE] event and closes the response stream.
      #
      # Pass close: false to run one turn of a multi-turn exchange over a
      # single open response (e.g. a controller relaying several agents in
      # sequence): the response stays open so the caller can write its own
      # events (a turn-boundary signal, another stream_agent call) before the
      # final call in the sequence closes with close: true.
      #
      # close: false is only honored on the success path. Any error always
      # writes [DONE] and closes — there is no next turn to hand the open
      # response to once a turn has failed.
      #
      # on_error is after_stream's counterpart for the failure path: called
      # with the raised exception once the SSE error event has been written,
      # so a caller can persist a record of the failed attempt (cost so far,
      # what failed, when) the same way after_stream lets it persist a
      # successful one. Optional and nil by default — existing callers that
      # don't pass it see no change in behavior. A raise inside on_error is
      # caught and logged here rather than left to propagate: a bug in the
      # caller's own bookkeeping must not prevent the client from getting its
      # error event and terminal [DONE].
      def stream_agent(agent, close: true, on_error: nil, &after_stream)
        response.headers["Content-Type"]      = "text/event-stream"
        response.headers["Cache-Control"]     = "no-cache"
        response.headers["X-Accel-Buffering"] = "no"

        full_response  = String.new
        @stream_errored = false

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
        @stream_errored = true
        Rails.logger.error("stream_conversation failed: #{stream_error.class} #{stream_error.message}")
        response.stream.write("data: #{JSON.generate(error: stream_error_message(stream_error))}\n\n") rescue nil
        begin
          on_error&.call(stream_error)
        rescue => callback_error
          Rails.logger.error("stream_agent on_error callback failed: #{callback_error.class} #{callback_error.message}")
        end
        full_response
      ensure
        # Must run even if after_stream raised — client hangs otherwise.
        if close || @stream_errored
          response.stream.write("data: [DONE]\n\n") rescue nil
          response.stream.close
        end
      end

      private

      # Whether the most recent stream_agent call ended in an error. A chain-
      # orchestrating caller checks this after a close: false call to decide
      # whether to run the next turn — stream_agent has already emitted the
      # scoped error event and closed the response in that case.
      def stream_errored?
        @stream_errored
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
          # The provider's own explanation, already cleaned, then older message formats, then a generic line.
          error.provider_message.presence ||
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
