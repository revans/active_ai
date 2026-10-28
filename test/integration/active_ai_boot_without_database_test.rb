require "test_helper"
require "open3"
require "rbconfig"

# An app that uses ActiveAI must boot, eager loaded, without a database connection: a fresh
# checkout, an asset build, a CI scratch worktree. Production eager loads every class the gem
# ships, so none of them may touch the database while loading (Atlas F-066).
class ActiveAIBootWithoutDatabaseTest < ActiveSupport::TestCase
  BOOT = <<~RUBY
    ENV["RAILS_ENV"] = "test"
    ENV["DATABASE_URL"] = "sqlite3:/nonexistent-active-ai-dir/never.sqlite3"
    require File.expand_path("test/dummy/config/application", Dir.pwd)
    Rails.application.config.eager_load = true
    Rails.application.initialize!
    Rails.application.eager_load!
    puts "booted"
  RUBY

  test "an app eager loads every ActiveAI class with no database to connect to" do
    out, err, status = Open3.capture3(RbConfig.ruby, "-e", BOOT, chdir: File.expand_path("../..", __dir__))

    assert status.success?, "boot failed:\n#{err.lines.first(8).join}"
    assert_includes out, "booted"
  end
end
