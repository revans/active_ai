module ActiveAI
  UNLIMITED = :unlimited

  # The one definition of a valid output-token limit, used by the agent DSL, ai.yml, and the tool and
  # orchestrator bases: a positive Integer, or :unlimited ("unlimited" from YAML is accepted too).
  #
  # :unlimited means "do not constrain the answer below what the model can do". OpenAI and xAI omit the limit
  # parameter; Anthropic requires one, so the model's own maximum output is sent (looked up from its models API).
  def self.token_limit(value, name: "max_tokens")
    return UNLIMITED if value.to_s.strip.downcase == "unlimited"
    return value if value.is_a?(Integer) && value.positive?
    return value.to_i if value.is_a?(String) && value.match?(/\A\d+\z/) && value.to_i.positive?

    raise ArgumentError, "#{name} must be a positive Integer or :unlimited, got #{value.inspect}"
  end
end
