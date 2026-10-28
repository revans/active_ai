module ActiveAI
  # Declares what of a model an LLM may read through ActiveAI::Tools::RecordQuery.
  # Nothing is readable until declared: an association not listed cannot be walked,
  # a scope or class method not listed cannot be called, an attribute not listed
  # is never returned.
  #
  #   class Account < ApplicationRecord
  #     include ActiveAI::Readable
  #     ai_readable associations: [:orders,
  #                                 { audit_entries: { if: ->(account, user) { user.admin_of?(account) } } }]
  #   end
  #
  #   class Order < ApplicationRecord
  #     include ActiveAI::Readable
  #     ai_readable scopes:     { shipped: "Orders that have shipped",
  #                               since:   "Orders placed on or after a date (YYYY-MM-DD)" },
  #                 attributes: %i[number status placed_at total]
  #   end
  #
  # `scopes:` takes scope names or class methods that return a relation of the
  # model, as an array or as a hash of name => description shown to the model.
  # An association's `if:` receives the record and the tool's `context:`.
  module Readable
    extend ActiveSupport::Concern

    included do
      class_attribute :ai_readable_associations, instance_accessor: false, default: {}
      class_attribute :ai_readable_scopes,       instance_accessor: false, default: {}
      class_attribute :ai_readable_attributes,   instance_accessor: false, default: []
    end

    class_methods do
      def ai_readable(associations: [], scopes: [], attributes: [])
        self.ai_readable_associations = ai_readable_associations.merge(normalize_ai_associations(associations))
        self.ai_readable_scopes       = ai_readable_scopes.merge(normalize_ai_scopes(scopes))
        self.ai_readable_attributes   = (ai_readable_attributes + attributes.map(&:to_sym)).uniq
      end

      def ai_readable_association?(name, record, context)
        return false unless ai_readable_associations.key?(name.to_sym)

        condition = ai_readable_associations[name.to_sym][:if]
        condition.nil? || condition.call(record, context) ? true : false
      end

      private

      def normalize_ai_associations(associations)
        Array(associations).each_with_object({}) do |entry, hash|
          if entry.is_a?(Hash)
            entry.each { |name, options| hash[name.to_sym] = { if: options[:if] } }
          else
            hash[entry.to_sym] = { if: nil }
          end
        end
      end

      def normalize_ai_scopes(scopes)
        return scopes.to_h { |name, description| [name.to_sym, description.to_s] } if scopes.is_a?(Hash)

        Array(scopes).to_h { |name| [name.to_sym, nil] }
      end
    end
  end
end
