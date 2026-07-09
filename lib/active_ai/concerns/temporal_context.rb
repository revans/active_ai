module ActiveAI
  module Concerns
    # Prefixes a history/current message with when it was actually sent, so
    # an agent can reason about real elapsed time instead of guessing from
    # token cadence (e.g. confidently saying "in the last hour" after 20
    # minutes).
    #
    # This concern does not wire itself into every ActiveAI::Agent::Base
    # subclass automatically — it depends on a hook convention the gem itself
    # does not define or call: your own build_messages must call
    # history_message_content(msg) for each history row and
    # current_message_content for the live message. If your build_messages
    # builds message hashes some other way, including this concern does
    # nothing. See test/integration/active_ai_temporal_context_test.rb for a
    # worked example of the convention this concern expects.
    #
    # Only user-role history messages are stamped, never the agent's own past
    # replies — stamping assistant history teaches the model, by example, to
    # start its own new replies with a timestamp too (it copies the pattern
    # it's shown).
    #
    #   class WritingAgent < ApplicationAgent
    #     include ActiveAI::Concerns::TemporalContext
    #   end
    module TemporalContext
      extend ActiveSupport::Concern

      private

      def history_message_content(msg)
        return super unless msg.role.to_s == "user"
        "#{stamp(msg.created_at)}#{super}"
      end

      def current_message_content
        "#{stamp(Time.current)}#{super}"
      end

      def stamp(time)
        "[#{time.strftime("%Y-%m-%d %-l:%M %p %Z")}] "
      end
    end
  end
end
