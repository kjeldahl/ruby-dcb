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

entry = {
  "timestamp" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
  "commit" => ENV.fetch("GITHUB_SHA", "unknown")[0, 7],
  "line_percent" => (metrics["covered_percent"] || 0).round(2),
  "covered_lines" => metrics["covered_lines"] || 0,
  "total_lines" => metrics["total_lines"] || 0,
  "branch_percent" => (metrics.dig("covered_percent") || 0).round(2)
}

history = File.exist?(history_path) ? JSON.parse(File.read(history_path)) : []
history << entry
# Keep last 100 entries
history = history.last(100)

File.write(history_path, JSON.pretty_generate(history))
puts "Coverage history updated: #{entry['line_percent']}% (#{entry['commit']})"
