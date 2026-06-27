class WritingAgent < ApplicationAgent
  # Built-in tools (opt-in):
  # tools ActiveAI::Tools::WebSearch      # requires FIRECRAWL_API_KEY in ENV
  # tools ActiveAI::Tools::WebPageReader  # no key required

  private

  def build_params
    super.merge(
      # system: prompt(:writing)  # loads app/ai/prompts/writing.md
    )
  end
end
