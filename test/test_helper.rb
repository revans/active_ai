ENV["RAILS_ENV"] = "test"
require File.expand_path("dummy/config/environment", __dir__)
require "rails/test_help"

class ActiveSupport::TestCase
  # No fixtures needed for gem integration tests
  self.use_transactional_tests = false
end
