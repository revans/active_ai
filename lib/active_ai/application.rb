require "singleton"

module ActiveAI
  # The ActiveAI application object — accessible via Rails.application.active_ai.
  # Analogous to Rails.application itself: a single instance that accumulates
  # capabilities as the framework grows.
  #
  #   Rails.application.active_ai.prompt(:writing)   # => "You are a writing assistant..."
  #
  class Application
    include Singleton

    PROMPT_EXTENSIONS = %w[md txt].freeze

    # Returns the contents of app/ai/prompts/<name>.<ext> as a string.
    # Checks .md first, then .txt. Raises if no file is found.
    #
    # In production the result is memoized — prompts are static at deploy time.
    # In development the file is re-read on every call so edits take effect
    # without a restart (same lifecycle as view templates).
    #
    def prompt(name)
      if Rails.env.production?
        @prompt_cache ||= {}
        @prompt_cache[name.to_sym] ||= read_prompt(name)
      else
        read_prompt(name)
      end
    end

    private

    def read_prompt(name)
      path = find_prompt_path(name)
      raise ActiveAI::MissingPromptError, "No prompt file found for :#{name}. " \
        "Create app/ai/prompts/#{name}.md (or .txt)." unless path
      File.read(path)
    end

    def find_prompt_path(name)
      PROMPT_EXTENSIONS.each do |ext|
        path = Rails.root.join("app", "ai", "prompts", "#{name}.#{ext}")
        return path if path.exist?
      end
      nil
    end
  end
end
