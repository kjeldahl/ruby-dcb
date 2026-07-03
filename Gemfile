source "https://rubygems.org"
gemspec

# The k6 conformance/benchmark adapter (bench/k6) and the event browser
# example (examples/config.ru). Optional so the test and lint jobs skip them:
# `bundle config set --local with bench web` to install.
group :bench, :web, optional: true do
  gem "puma", "~> 7.0"
end

group :web, optional: true do
  gem "rackup", "~> 2.2"
end
