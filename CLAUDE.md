# active_ai gem

## Generator naming

Rails converts `ActiveAI` via `underscore` to `active_a_i`, which causes generators to
be listed in `--help` (filesystem glob) but fail to invoke (path lookup mismatch).

**Fix:** every generator must explicitly declare its namespace:

```ruby
class AgentGenerator < Rails::Generators::NamedBase
  namespace "active_ai:agent"   # overrides the default active_a_i:agent
end
```

Generator directories stay at `lib/generators/active_ai/` — the explicit `namespace`
declaration makes the path lookup match. Without it, `bin/rails g active_a_i:agent`
appears to work in `--help` but always fails on invocation.
