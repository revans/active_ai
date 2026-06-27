class ApplicationTool < ActiveAI::Tool::Base
  include ActiveAI::Promptable
  prompt_namespace :tool
end
