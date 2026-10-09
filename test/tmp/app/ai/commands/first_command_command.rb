class FirstCommandCommand < ApplicationCommand
  command_name "first_command"
  description "TODO: describe what FirstCommandCommand does"

  # Exactly one of phrase: (exact match, no argument) or prefix: (leading
  # match, captures trailing text as the `argument:` call kwarg):
  trigger phrase: "/first command"
  # trigger prefix: "/first command"

  # :stream (SSE) or :json (single response.json() await):
  response_type :json

  def call(argument: nil)
    raise NotImplementedError, "#{self.class}#call is not implemented"
  end
end
