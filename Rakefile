require "rake/testtask"

# Files the suite generates or rewrites are not tests: generator output goes to a temp dir (see the
# generator tests), the dummy app only hosts the suite, and live/ calls real APIs and is opt-in.
OFFLINE_TESTS = FileList["test/**/*_test.rb"].exclude("test/tmp/**/*", "test/dummy/**/*", "test/live/**/*")

Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.test_files = OFFLINE_TESTS
  task.description = "Run the offline suite (no network, no API keys)"
end

namespace :test do
  Rake::TestTask.new(:live) do |task|
    task.libs << "test"
    task.test_files = FileList["test/live/**/*_test.rb"]
    task.description = "Contract tests against the real provider APIs (needs OPENAI_API_KEY / ANTHROPIC_API_KEY; costs a few cents)"
  end

  task :live_env do
    ENV["ACTIVE_AI_LIVE"] = "1"
  end
  task live: :live_env
end

task default: :test
