#!/usr/bin/env ruby
# frozen_string_literal: true

# Compares coverage between base branch and current PR branch.
# Reads SimpleCov JSON output and produces a markdown summary.
#
# Usage:
#   ruby scripts/coverage_report.rb <base_coverage.json> <pr_coverage.json>

require "json"

def load_coverage(path)
  data = JSON.parse(File.read(path))
  result = data.fetch("result", data)
  metrics = result.fetch("metrics", {})

  file_coverage = {}
  (result["coverage"] || result.dig("groups") || {}).each do |file_path, file_data|
    next unless file_path.end_with?(".rb")

    lines = file_data.is_a?(Hash) ? file_data["lines"] : file_data
    next unless lines.is_a?(Array)

    relevant = lines.compact
    covered = relevant.count { |hits| hits > 0 }
    total = relevant.size
    pct = total > 0 ? (covered.to_f / total * 100).round(2) : 100.0

    short_path = file_path.sub(%r{.*/lib/}, "lib/")
    file_coverage[short_path] = { covered: covered, total: total, percent: pct }
  end

  {
    line_percent: metrics.fetch("covered_percent", 0).round(2),
    covered_lines: metrics.fetch("covered_lines", 0),
    total_lines: metrics.fetch("total_lines", 0),
    files: file_coverage
  }
end

def delta_icon(delta)
  if delta > 0.5
    "+"
  elsif delta < -0.5
    "!!"
  else
    " "
  end
end

def format_delta(delta)
  sign = delta >= 0 ? "+" : ""
  "#{sign}#{delta.round(2)}%"
end

if ARGV.length == 1
  # Single report mode — just summarize current coverage
  pr = load_coverage(ARGV[0])

  puts "## Coverage Report"
  puts ""
  puts "**Overall: #{pr[:line_percent]}%** (#{pr[:covered_lines]}/#{pr[:total_lines]} lines)"
  puts ""
  puts "| File | Coverage | Lines |"
  puts "|------|----------|-------|"

  pr[:files].sort_by { |path, _| path }.each do |path, data|
    puts "| `#{path}` | #{data[:percent]}% | #{data[:covered]}/#{data[:total]} |"
  end

  exit 0
end

if ARGV.length != 2
  warn "Usage: ruby scripts/coverage_report.rb <base_coverage.json> [pr_coverage.json]"
  exit 1
end

base = load_coverage(ARGV[0])
pr = load_coverage(ARGV[1])

overall_delta = pr[:line_percent] - base[:line_percent]

puts "## Coverage Change Report"
puts ""
puts "| | Base | PR | Delta |"
puts "|---|------|-----|-------|"
puts "| **Overall** | #{base[:line_percent]}% | #{pr[:line_percent]}% | #{format_delta(overall_delta)} |"
puts "| **Lines** | #{base[:covered_lines]}/#{base[:total_lines]} | #{pr[:covered_lines]}/#{pr[:total_lines]} | |"
puts ""

# Collect all files from both reports
all_files = (base[:files].keys + pr[:files].keys).uniq.sort

changed_files = all_files.select do |path|
  base_pct = base[:files].dig(path, :percent) || 0.0
  pr_pct = pr[:files].dig(path, :percent) || 0.0
  (pr_pct - base_pct).abs > 0.01 ||
    !base[:files].key?(path) ||
    !pr[:files].key?(path)
end

if changed_files.empty?
  puts "No per-file coverage changes detected."
else
  puts "### Changed Files"
  puts ""
  puts "| Status | File | Base | PR | Delta |"
  puts "|--------|------|------|-----|-------|"

  changed_files.each do |path|
    base_data = base[:files][path]
    pr_data = pr[:files][path]

    if base_data.nil?
      puts "| NEW | `#{path}` | — | #{pr_data[:percent]}% | — |"
    elsif pr_data.nil?
      puts "| DEL | `#{path}` | #{base_data[:percent]}% | — | — |"
    else
      delta = pr_data[:percent] - base_data[:percent]
      icon = delta_icon(delta)
      puts "| #{icon} | `#{path}` | #{base_data[:percent]}% | #{pr_data[:percent]}% | #{format_delta(delta)} |"
    end
  end
end

# Exit with non-zero if coverage dropped significantly
if overall_delta < -1.0
  warn "\nWarning: Overall coverage dropped by #{format_delta(overall_delta)}"
  exit 1
end
