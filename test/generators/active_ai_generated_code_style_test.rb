require "test_helper"
require "tmpdir"
require "json"
require "rails/generators"
require "rubocop"
Dir[File.expand_path("../../lib/generators/active_ai/**/*_generator.rb", __dir__)].each { |file| require file }

# Every generator runs to completion, and what it writes passes rubocop-rails-omakase — the
# style a new Rails app lints with — so an app never edits generated code to make CI pass.
class ActiveAIGeneratedCodeStyleTest < ActiveSupport::TestCase
  RUNS = {
    "active_ai:install"        => [ [] ],
    "active_ai:evaluation"     => [ [] ],
    "active_ai:credentials"    => [ [] ],
    "active_ai:memory:install" => [ [], [ "--vector=pgvector" ] ],
    "active_ai:event_log"      => [ [ "--link-to=messages" ], [ "--timescaledb" ] ],
    "active_ai:agent"          => [ [ "Writing" ] ],
    "active_ai:tool"           => [ [ "PriceCheck" ] ],
    "active_ai:skill"          => [ [ "Tone" ] ],
    "active_ai:command"        => [ [ "LeaveEditor" ] ],
    "active_ai:orchestrator"   => [ [ "Editor" ] ],
    "active_ai:workflow"       => [ [ "Research" ] ],
    "active_ai:prompt"         => [ [ "agent", "writing" ] ]
  }.freeze

  CONFIG = <<~YAML
    inherit_gem: { rubocop-rails-omakase: rubocop.yml }
    AllCops:
      NewCops: disable
      TargetRubyVersion: 3.4
  YAML

  test "every generator's output passes rubocop-rails-omakase" do
    Dir.mktmpdir("active_ai_style") do |root|
      RUNS.each do |name, option_sets|
        option_sets.each_with_index do |options, index|
          app = File.join(root, "#{name.tr(':', '_')}_#{index}")
          FileUtils.mkdir_p(app)
          File.write(File.join(app, "Gemfile"), "source \"https://rubygems.org\"\n")
          out, err = capture_io { Rails::Generators.invoke(name, options + [ "--quiet" ], destination_root: app) }
          assert_no_match(/could not find|error/i, out + err, "#{name} #{options.join(' ')} reported a problem")
          assert_not_empty Dir[File.join(app, "{app,db,config,lib,test}/**/*.*")], "#{name} #{options.join(' ')} wrote nothing"
        end
      end

      File.write(File.join(root, ".rubocop.yml"), CONFIG)
      report = File.join(root, "rubocop.json")
      capture_io { RuboCop::CLI.new.run([ "--config", File.join(root, ".rubocop.yml"), "--format", "json", "--out", report, root ]) }

      offenses = JSON.parse(File.read(report))["files"].flat_map do |file|
        file["offenses"].map { |offense| "#{file['path'].delete_prefix(root)}:#{offense.dig('location', 'line')} #{offense['cop_name']}" }
      end
      assert_empty offenses, "generated code must pass rubocop-rails-omakase:\n#{offenses.join("\n")}"
    end
  end
end
