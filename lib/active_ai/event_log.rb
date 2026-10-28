module ActiveAI
  # Stores ActiveAI's events as rows, so a run can be rebuilt from its prompts, answers,
  # tool calls and queries. Include it in the model `rails g active_ai:event_log` generates.
  #
  #   ActiveSupport::Notifications.subscribe(/\.active_ai\z/) { |event| AiEvent.record(event) }
  #
  #   AiEvent.for_run(response.run_id)   # every event of a run, oldest first
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
