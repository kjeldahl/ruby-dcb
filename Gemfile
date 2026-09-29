source "https://rubygems.org"
gemspec

# The k6 conformance/benchmark adapter (bench/k6). Optional so the test and
# lint jobs skip it: `bundle config set --local with bench` to install.
group :bench, optional: true do
  gem "puma", "~> 7.0"
end
