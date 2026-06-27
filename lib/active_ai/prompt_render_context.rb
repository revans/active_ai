module ActiveAI
  # Acts as `self` inside ERB prompt templates. Wraps an agent/tool/memory
  # instance to delegate its methods and @ivars, while adding rendering helpers
  # so prompt files can include other prompt files (partials and skills).
  #
  # Analogous to ActionView::Base wrapping a controller — the template sees all
  # the instance's state plus the helper methods, without the instance class
  # needing to know about the rendering system.
  #
  class PromptRenderContext
    def initialize(agent, resolver)
      @_resolver = resolver
      @_agent    = agent
      return unless agent

      agent.instance_variables.each do |ivar|
        next if ivar.to_s.start_with?("@_")
        instance_variable_set(ivar, agent.instance_variable_get(ivar))
      end
    end

    # Renders a prompt file from the same directory as the current template.
    # Context (self, @ivars) passes through to the partial unchanged.
    #
    #   <%= partial :tone_guide %>
    #   <%= partial :voice, register: "formal" %>
    #
    def partial(name, **locals)
      @_resolver._render_partial(name, self, **locals)
    end

    # Renders a prompt from app/ai/skills/prompts/<name>.md.erb.
    # Lets any agent pull a shared skill definition into its system prompt.
    #
    #   <%= skill :writing_style %>
    #   <%= skill :citation_rules, format: :apa %>
    #
    def skill(name, **locals)
      ActiveAI.skill._prompt_in_context(name, self, **locals)
    end

    def method_missing(method_name, *args, **kwargs, &block)
      return super unless @_agent
      @_agent.send(method_name, *args, **kwargs, &block)
    end

    def respond_to_missing?(method_name, include_private = false)
      (@_agent&.respond_to?(method_name, include_private)) || super
    end
  end
end
