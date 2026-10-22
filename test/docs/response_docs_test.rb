require "test_helper"

# The Response docs are the contract an app codes against. These fail if the code and the docs drift apart.
class ResponseDocsTest < ActiveSupport::TestCase
  DOC = File.read(File.expand_path("../../docs/response.md", __dir__))

  def field_table_rows
    DOC[/### Field reference.*?(?=\n###)/m].scan(/^\| `(\w+)` \|/).flatten
  end

  test "every Response field is in the field reference, and nothing else is" do
    assert_equal ActiveAI::Response.members.map(&:to_s).sort, field_table_rows.sort
  end

  test "the JSON skeleton lists exactly the fields as_json returns" do
    skeleton = DOC[/## What to expect back.*?```json\n(.*?)\n```/m, 1]
    keys = skeleton.scan(/^  "(\w+)":/).flatten
    assert_equal build_response_keys.sort, keys.sort
  end

  test "the usage table lists every key a provider reports" do
    usage_keys = DOC[/### `usage`.*?(?=\nCounts are summed)/m].scan(/^\| `(\w+)` \|/).flatten
    openai = ActiveAI::Provider::OpenAI.new.send(:normalize_usage, { "prompt_tokens" => 1 }).keys.map(&:to_s)
    assert_equal openai.sort, usage_keys.sort
  end

  test "every documented finish reason is in the published vocabulary" do
    documented = DOC[/`finish_reason`[^\n]*\n/].scan(/"(\w+)"/).flatten.map(&:to_sym) # the skeleton line
    assert_empty documented - ActiveAI::Response::FINISH_REASONS
  end

  test "the real example JSON blocks carry exactly the documented fields" do
    blocks = DOC.scan(/```json\n(.*?)\n```/m).flatten.reject { |block| block.include?("//") }
    assert_operator blocks.size, :>=, 8
    blocks.each { |block| assert_equal ActiveAI::Response.members.map(&:to_s).sort, JSON.parse(block).keys.sort }
  end

  private

  def build_response_keys = ActiveAI::Response.members.map(&:to_s)
end
