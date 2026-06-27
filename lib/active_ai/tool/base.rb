require "active_support/core_ext/class/attribute"

module ActiveAI
  module Tool
    # Base class for AI tools. Supports two registration styles:
    #
    # Class-based (stateless tools):
    #
    #   class WebSearchTool < ApplicationTool
    #     tool_name "web_search"
    #     description "Search the web"
    #     def self.parameters = { query: { type: "string", description: "The search query" } }
    #     def call(query:) = adapter.search(query)
    #   end
    #
    #   tool WebSearchTool
    #
    # Instance-based (tools that need injected context, e.g. the current document):
    #
    #   class WriteDocumentTool < ApplicationTool
    #     tool_name "write_document"
    #     description "Replace the document body"
    #     def self.parameters = { body: { type: "string", description: "New document content" } }
    #
    #     def initialize(document:)
    #       @document = document
    #     end
    #
    #     def call(body:)
    #       @document.update!(body: body)
    #       "Document updated."
    #     end
    #   end
    #
    #   tool WriteDocumentTool.new(document: @document)
    #
    # Tools can also make their own LLM calls using the provider/model/system_prompt
    # DSL and the complete() instance method:
    #
    #   class SummarizeTool < ApplicationTool
    #     tool_name "summarize"
    #     description "Summarizes the provided text"
    #     def self.parameters = { text: { type: "string", description: "Text to summarize" } }
    #
    #     provider :anthropic
    #     model "claude-haiku-4-5-20251001", max_tokens: 512
    #     system_prompt "Return a one-sentence summary. Nothing else."
    #
    #     def call(text:)
    #       complete(text)
    #     end
    #   end
    #
    # In all cases the agent loop calls tool.tool_name, tool.to_definition,
    # and tool.call(**inputs) — the instance methods below delegate to the
    # class so instances expose the same interface as classes.
    class Base
      include ActiveAI::Concerns::Describable

      class_attribute :_provider_name, :_model_config, :_system_prompt, :_tool_name
      class_attribute :_params, default: []

      # ── LLM configuration DSL ───────────────────────────────────────────────

      def self.provider(name)
        self._provider_name = name.to_sym
      end

      def self.model(name, max_tokens: nil)
        self._model_config = { name: name, max_tokens: max_tokens }
      end

      def self.system_prompt(text)
        self._system_prompt = text
      end

      # ── Tool identity DSL ───────────────────────────────────────────────────

      def self.call(**inputs)
        new.call(**inputs)
      end

      def call(**inputs)
        raise NotImplementedError, "#{self.class}#call is not implemented"
      end

      def self.tool_name(text = nil)
        if text
          self._tool_name = text
          self
        else
          _tool_name || raise(NotImplementedError, "#{self}.tool_name is not implemented — call `tool_name \"...\"`")
        end
      end

      # Declarative parameter DSL. Additive — call multiple times for multiple params.
      # Replaces the old `def self.parameters = { ... }` pattern.
      #
      #   param :query, type: :string, description: "The search query"
      #   param :limit, type: :integer, description: "Max results", required: false
      def self.param(name, type:, description:, required: true)
        self._params = _params + [{ name: name, type: type, description: description, required: required }]
      end

      # Returns parameters as an Anthropic-compatible properties hash.
      # Derived from _params when the param DSL is used; override def self.parameters
      # directly for backwards-compatible hash-style declarations.
      def self.parameters
        _params.each_with_object({}) do |p, hash|
          hash[p[:name]] = { type: p[:type].to_s, description: p[:description] }
        end
      end

      # Returns the Anthropic-compatible tool definition hash.
      # When param DSL is used: only params declared with required: true appear in
      # the required array, enabling optional parameters. When parameters is
      # overridden directly (backwards compat): all keys are marked required.
      def self.to_definition
        {
          name:         tool_name,
          description:  description,
          input_schema: {
            type:       "object",
            properties: parameters,
            required:   _params.any? ? _params.select { |p| p[:required] }.map { |p| p[:name].to_s }.uniq
                                     : parameters.keys.map(&:to_s)
          }
        }
      end

      # Instance delegates — allow instances to be stored in _tools alongside
      # classes and respond to the same interface without extra dispatch logic.
      def tool_name     = self.class.tool_name
      def description   = self.class.description
      def parameters    = self.class.parameters
      def to_definition = self.class.to_definition
      def _params       = self.class._params

      private

      # Makes a blocking LLM call using this tool's provider/model/system_prompt.
      # Returns the response text. Requires provider, model, and system_prompt
      # to be declared on the tool class.
      def complete(prompt)
        provider_instance.call(build_canonical(prompt))
      end

      def build_canonical(prompt)
        {
          model:        resolved_model,
          max_tokens:   (self.class._model_config&.fetch(:max_tokens, nil) || ActiveAI.config.max_tokens),
          system:       self.class._system_prompt.to_s,
          skills:       [],
          source_files: [],
          messages:     [ { role: "user", content: prompt } ],
          cacheable:    {},
          tools:        []
        }
      end

      def resolved_provider
        (self.class._provider_name || ActiveAI.config.provider).to_sym
      end

      def resolved_model
        model_config = self.class._model_config
        return ActiveAI.config.model unless model_config
        model_name = model_config[:name]
        model_name.respond_to?(:call) ? model_name.call : model_name
      end

      def provider_instance
        ActiveAI.provider_class_for(resolved_provider).new
      end
    end
  end
end
