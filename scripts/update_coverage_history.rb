#!/usr/bin/env ruby
# frozen_string_literal: true

# Appends the current coverage result to a history JSON file.
# Used by CI to track coverage over time for the chart on GitHub Pages.
#
# Usage:
#   ruby scripts/update_coverage_history.rb <coverage.json> <history.json>

require "json"

coverage_path = ARGV[0] || "coverage/coverage.json"
history_path = ARGV[1] || "coverage_history.json"

data = JSON.parse(File.read(coverage_path))
metrics = data.dig("result", "metrics") || data.fetch("metrics", {})

# simplecov-json has no branch metrics; sum each file's branch hits.
# Shape: { "[:if, ...]" => { "[:then, ...]" => hits, ... }, ... }
branch_hits = data.fetch("files", []).flat_map do |file|
  branches = file.dig("coverage", "branches")
  branches.is_a?(Hash) ? branches.values.flat_map(&:values) : []
end
branch_percent =
  if branch_hits.empty?
    nil
  else
    (branch_hits.count(&:positive?).to_f / branch_hits.size * 100).round(2)
  end

entry = {
  "timestamp" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
  "commit" => ENV.fetch("GITHUB_SHA", "unknown")[0, 7],
  "line_percent" => (metrics["covered_percent"] || 0).round(2),
  "covered_lines" => metrics["covered_lines"] || 0,
  "total_lines" => metrics["total_lines"] || 0,
  "branch_percent" => branch_percent
}

history = File.exist?(history_path) ? JSON.parse(File.read(history_path)) : []
history << entry
# Keep last 100 entries
history = history.last(100)

File.write(history_path, JSON.pretty_generate(history))
puts "Coverage history updated: #{entry['line_percent']}% (#{entry['commit']})"
