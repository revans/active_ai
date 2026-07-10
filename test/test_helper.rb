ENV["RAILS_ENV"] = "test"
require File.expand_path("dummy/config/environment", __dir__)
require "rails/test_help"

previous_verbosity = ActiveRecord::Schema.verbose
ActiveRecord::Schema.verbose = false
load File.expand_path("dummy/db/schema.rb", __dir__)
ActiveRecord::Schema.verbose = previous_verbosity

require File.expand_path("support/net_http_stub", __dir__)

class ActiveSupport::TestCase
  # No fixtures needed for gem integration tests
  self.use_transactional_tests = false
end
