module ActiveAI
  # Stores an API credential for any named service — LLM providers or tool services.
  # Think of it like a keychain: one slot per service per owner, category tells you what kind.
  #
  #   Setting.instance.ai_credentials.create!(category: "provider", name: "anthropic", api_key: "sk-ant-...")
  #   Setting.instance.ai_credentials.create!(category: "tool",     name: "firecrawl", api_key: "fc-...")
  #
  class Credential < ActiveRecord::Base
    self.table_name = "ai_credentials"

    belongs_to :owner, polymorphic: true
    encrypts :api_key

    CATEGORIES = %w[provider tool].freeze

    DEFAULT_PROVIDER_NAMES = %w[anthropic openai xai].freeze
    DEFAULT_TOOL_NAMES     = %w[firecrawl brave tavily].freeze

    class_attribute :provider_names, default: DEFAULT_PROVIDER_NAMES
    class_attribute :tool_names,     default: DEFAULT_TOOL_NAMES

    scope :providers, -> { where(category: "provider") }
    scope :tools,     -> { where(category: "tool") }

    validates :category, presence: true, inclusion: { in: CATEGORIES }
    validates :name,     presence: true
    validates :api_key,  presence: true
    validates :name,     uniqueness: { scope: [:owner_type, :owner_id, :category] }
    validate  :name_is_registered

    def self.valid_names_for(category)
      case category.to_s
      when "provider" then provider_names
      when "tool"     then tool_names
      else []
      end
    end

    private

    def name_is_registered
      valid = self.class.valid_names_for(category)
      return if valid.blank?
      errors.add(:name, "#{name.inspect} is not a registered #{category}") unless valid.include?(name.to_s)
    end
  end
end
