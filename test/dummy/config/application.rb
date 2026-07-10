require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "action_controller/railtie"
require "active_ai"

module Dummy
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.active_record.maintain_test_schema = false
    config.active_job.queue_adapter = :test
  end
end
