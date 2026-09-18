Gem::Specification.new do |s|
  s.name        = "dcb_event_store"
  s.version     = "0.2.0"
  s.summary     = "DCB-compliant event store backed by PostgreSQL or SQLite"
  s.authors     = ["Jacob"]
  s.files       = Dir["lib/**/*.rb"]
  s.required_ruby_version = ">= 3.3"

  s.add_dependency "logger", "~> 1.6"

  # The database drivers are optional: an application adds the one matching
  # the backend it uses (`pg` for PostgresStore, `sqlite3` for SqliteStore),
  # so neither gem is a hard dependency of this one.
  s.add_development_dependency "pg", "~> 1.5"
  s.add_development_dependency "sqlite3", "~> 2.0"

  # Rails is not a dependency: ActiveSupportInstrumentation and the railtie
  # load only when the application already has them.
  s.add_development_dependency "activesupport", ">= 7.1"
  s.add_development_dependency "railties", ">= 7.1"
  s.add_development_dependency "minitest", "~> 5.0"
  s.add_development_dependency "concurrent-ruby", "~> 1.2"
  s.add_development_dependency "rake", "~> 13.0"
  s.add_development_dependency "rubocop", "~> 1.0"
  s.add_development_dependency "simplecov", "~> 0.22"
  s.add_development_dependency "simplecov-json", "~> 0.2"
  s.add_development_dependency "mutant-minitest", "~> 0.12"
end
