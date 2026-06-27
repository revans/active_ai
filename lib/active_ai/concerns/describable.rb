module ActiveAI
  module Concerns
    # Shared DSL for the description() setter/getter across agents, workflows,
    # and tools. Calling description("...") stores the text and self-registers
    # the class in ActiveAI.registry for runtime discovery. Calling description()
    # with no argument returns the stored text or raises if none was declared.
    #
    # Including classes do not need to declare class_attribute :_description —
    # this concern handles it.
    module Describable
      extend ActiveSupport::Concern

      included do
        class_attribute :_description
      end

      class_methods do
        def description(text = nil)
          if text
            self._description = text
            ActiveAI.register(self) if name.present?
            self
          else
            _description || raise(NotImplementedError, "#{self}.description is not declared — call `description \"...\"`")
          end
        end
      end
    end
  end
end
