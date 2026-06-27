class SearchTool < ApplicationTool
  tool_name "search"
  description "TODO: describe what SearchTool does"

  # param :input, type: :string, description: "..."

  def call(**inputs)
    raise NotImplementedError, "#{self.class}#call is not implemented"
  end
end
