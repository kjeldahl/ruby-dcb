#!/usr/bin/env ruby
# frozen_string_literal: true

# Turns the k6 summary exports bench/k6/run.sh writes (<backend>-<test>.json)
# into a markdown table, and exits non-zero when a run is missing, a request
# failed, a conformance check failed or verified nothing, or an unrelated
# append (the parallel-writes test) was rejected.

require "json"

rows = []
problems = []

ARGV.each do |path|
  name = File.basename(path, ".json")
  backend, test = name.split("-", 2)
  unless File.exist?(path)
    problems << "#{name}: no k6 summary (see #{path.sub(/\.json\z/, '.log')})"
    next
  end

  m = JSON.parse(File.read(path)).fetch("metrics")
  appends = m.dig("dcb_append_count", "count").to_i
  conflicts = m.dig("dcb_append_error_rate", "value").to_f
  checks_ok = m.dig("checks", "passes").to_i
  checks_failed = m.dig("checks", "fails").to_i
  http_failed = m.dig("http_req_failed", "passes").to_i

  problems << "#{name}: #{http_failed} failed request(s)" if http_failed.positive?
  problems << "#{name}: #{checks_failed} failed check(s)" if checks_failed.positive?
  problems << "#{name}: no append ran" if appends.zero?
  problems << "#{name}: nothing verified" if test != "parallel-writes" && checks_ok.zero?
  if test == "parallel-writes" && conflicts.positive?
    problems << "#{name}: #{format('%.2f%%', conflicts * 100)} of unrelated appends rejected"
  end

  rows << [
    backend, test, appends, format("%.0f", m.dig("dcb_append_count", "rate").to_f),
    format("%.2f", m.dig("dcb_append_duration", "med").to_f),
    format("%.2f", m.dig("dcb_append_duration", "p(95)").to_f),
    format("%.1f%%", conflicts * 100),
    test == "parallel-writes" ? "-" : "#{checks_ok}/#{checks_ok + checks_failed}"
  ]
end

header = ["backend", "test", "appends", "appends/s", "append p50 ms", "append p95 ms", "conflicts", "checks passed"]
puts "| #{header.join(' | ')} |"
puts "|#{header.map { '---' }.join('|')}|"
rows.each { |row| puts "| #{row.join(' | ')} |" }

if problems.any?
  warn "\nFAILED:"
  problems.each { |p| warn "  #{p}" }
  exit 1
end
