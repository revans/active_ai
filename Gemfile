source "https://rubygems.org"

gemspec

group :development, :test do
  gem "sqlite3", ">= 2.1"
  gem "debug", platforms: %i[mri windows], require: "debug/prelude"
  # Generated code must pass the style a new Rails app lints with.
  gem "rubocop-rails-omakase", require: false
end
