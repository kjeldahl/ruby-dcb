Gem::Specification.new do |s|
  s.name        = "dcb_event_store"
  s.version     = "0.1.0"
  s.summary     = "DCB-compliant event store backed by PostgreSQL"
  s.authors     = ["Jacob"]
  s.files       = Dir["lib/**/*.rb"]
  s.required_ruby_version = ">= 3.3"

  s.add_dependency "pg", "~> 1.5"

  s.add_development_dependency "minitest", "~> 5.0"
  s.add_development_dependency "concurrent-ruby", "~> 1.2"
  s.add_development_dependency "rake", "~> 13.0"
  s.add_development_dependency "rubocop", "~> 1.0"
end
