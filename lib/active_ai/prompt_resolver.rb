require "erb"

module ActiveAI
  class PromptResolver
    class PromptNotFound < StandardError; end

    def initialize(relative_dir, root: nil)
      @relative_dir = relative_dir
      @root         = root
    end

    # Loads a system prompt from a file. Tries <name>.md.erb first (ERB rendered),
    # then falls back to <name>.md (plain text).
    #
    # Use at class load time for static prompts (e.g. in the system_prompt DSL):
    #
    #   system_prompt Rails.active_ai.agent.prompt(:embedder)
    #
    # Pass extra locals as keyword arguments — they become ERB variables:
    #
    #   Rails.active_ai.agent.prompt(:embedder, model: "haiku", budget: 1024)
    #
    # To render with a live instance in scope (instance methods + @ivars available),
    # use prompt_file from inside the instance — it handles context automatically.
    #
    def prompt(name, **locals)
      render_file(validate_name!(name), PromptRenderContext.new(nil, self), locals)
    end

    # Used by Promptable#prompt_file — renders with the calling instance as self
    # in ERB so instance methods and @ivars are directly accessible.
    def _prompt_in_context(name, context, **locals)
      render_context = context.is_a?(PromptRenderContext) ? context : PromptRenderContext.new(context, self)
      render_file(validate_name!(name), render_context, locals)
    end

    # Used by PromptRenderContext#partial — renders a same-directory include
    # with the existing render context passed through unchanged.
    def _render_partial(name, render_context, **locals)
      render_file(validate_name!(name), render_context, locals)
    end

    private

    def validate_name!(name)
      name_str = name.to_s
      raise ArgumentError, "Invalid prompt name #{name_str.inspect} — must not contain '/' or '..'" \
        if name_str.include?("/") || name_str.include?("..")
      name_str
    end

    def render_file(name_str, render_context, locals)
      base     = Pathname.new(@root || Rails.root)
      erb_path = base.join(@relative_dir, "#{name_str}.md.erb")
      md_path  = base.join(@relative_dir, "#{name_str}.md")

      if erb_path.exist?
        render_erb(erb_path.read, locals, render_context)
      elsif md_path.exist?
        md_path.read.strip
      else
        raise PromptNotFound, "No prompt file at #{erb_path} or #{md_path}"
      end
    end

    def render_erb(source, locals, render_context)
      erb_binding = render_context.instance_eval { binding }
      locals.each { |key, value| erb_binding.local_variable_set(key, value) }
      ERB.new(source, trim_mode: "-").result(erb_binding).strip
    end
  end
end
