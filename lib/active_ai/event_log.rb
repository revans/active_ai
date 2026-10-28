module ActiveAI
  # Stores ActiveAI's events as rows, so a run can be rebuilt from its prompts, answers,
  # tool calls and queries. Include it in the model `rails g active_ai:event_log` generates.
  #
  #   ActiveSupport::Notifications.subscribe(/\.active_ai\z/) { |event| AIEvent.record(event) }
  #
  #   AIEvent.for_run(response.run_id)   # every event of a run, oldest first
  #   AIEvent.request_for(span_id)        # the full request one provider call sent
  #
  # Recording never raises into the AI call it is logging: a failed insert is logged and
  # dropped. Override filter_payload to drop or redact keys before they are stored.
  module EventLog
    extend ActiveSupport::Concern

    included do
      scope :for_run,     ->(run_id) { where(run_id: run_id).order(:started_at, :id) }
      scope :for_span,    ->(span_id) { where(span_id: span_id).order(:started_at, :id) }
      scope :for_request, ->(request_id) { where(request_id: request_id).order(:started_at, :id) }
    end

    class_methods do
      def record(event)
        payload = event.payload
        create!(
          name:           event.name.delete_suffix(".active_ai"),
          run_id:         payload[:run_id],
          span_id:        payload[:span_id],
          parent_span_id: payload[:parent_span_id],
          request_id:     payload[:request_id],
          job_id:         payload[:job_id],
          caller_type:    payload[:caller_type]&.to_s,
          caller_name:    payload[:caller_name]&.to_s,
          started_at:     wall_clock(event.time),
          finished_at:    wall_clock(event.end),
          duration_ms:    event.duration&.round(3),
          error:          payload[:exception] && Array(payload[:exception]).join(": "),
          payload:        storable(filter_payload(event.name, payload.except(:exception, :exception_object)))
        )
      rescue StandardError => error
        Rails.logger.error("ActiveAI::EventLog could not record #{event.name}: #{error.class}: #{error.message}")
        nil
      end

      REQUEST_SETTINGS = %w[system skills source_files tools max_tokens response_schema options cacheable].freeze

      # The full request one provider call sent — settings, model and every message — rebuilt from the agent_request
      # events of its stream, which each store only what was new. nil when any of them is missing (skipped, pruned,
      # or failed to record), rather than a request with a hole in it.
      def request_for(span_id)
        request = find_by(name: "agent_request", span_id: span_id)
        return unless request

        turn   = request.payload["turn"].to_i
        stream = where(name: "agent_request", run_id: request.run_id, parent_span_id: request.parent_span_id)
                   .map(&:payload).select { |payload| payload["turn"].to_i <= turn }.sort_by { |payload| payload["turn"].to_i }
        return unless stream.map { |payload| payload["turn"].to_i } == (1..turn).to_a

        messages = []
        stream.each do |payload|
          return unless payload["messages_before"].to_i == messages.size

          messages.concat(Array(payload["messages"]))
        end

        stream.first.slice(*REQUEST_SETTINGS).merge("model" => request.payload["model"], "messages" => messages)
      end

      # Deletes events that started before older_than ago, in batches. Returns how many.
      #
      #   AIEvent.prune(older_than: 90.days)
      def prune(older_than:)
        where(started_at: ...older_than.ago).in_batches(of: 10_000).delete_all
      end

      # Override to drop or redact keys before a payload is stored. Must return a Hash.
      def filter_payload(_name, payload) = payload

      # Plain JSON data: records become their GlobalID (or "Class#id"), anything else that
      # cannot be expressed as JSON becomes its string form.
      def storable(value)
        case value
        when Hash                then value.to_h { |key, item| [key.to_s, storable(item)] }
        when Array               then value.map { |item| storable(item) }
        when ActiveRecord::Base  then value.try(:to_global_id)&.to_s || "#{value.class.name}##{value.id}"
        when nil, true, false, Numeric, String then value
        when Symbol              then value.to_s
        else
          value.respond_to?(:as_json) ? storable(value.as_json) : value.to_s
        end
      rescue StandardError
        value.to_s
      end

      private

      # Event#time and #end are monotonic-clock seconds; the row wants wall-clock times.
      def wall_clock(monotonic_seconds)
        return if monotonic_seconds.nil?

        Time.current - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - monotonic_seconds)
      end
    end
  end
end
