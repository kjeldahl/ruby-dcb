#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates the index.html for GitHub Pages that includes:
# - Link to full SimpleCov HTML report
# - Coverage-over-time chart using Chart.js
#
# Usage:
#   ruby scripts/generate_pages_index.rb <history.json> <output_dir>

require "json"

history_path = ARGV[0] || "coverage_history.json"
output_dir = ARGV[1] || "_site"

history = File.exist?(history_path) ? JSON.parse(File.read(history_path)) : []

labels = history.map { |e| e["commit"] }.to_json
data = history.map { |e| e["line_percent"] }.to_json
timestamps = history.map { |e| e["timestamp"] }.to_json

html = <<~HTML
  <!DOCTYPE html>
  <html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Coverage — ruby-dcb</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4"></script>
    <style>
      * { margin: 0; padding: 0; box-sizing: border-box; }
      body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
             max-width: 960px; margin: 0 auto; padding: 2rem; color: #24292f; }
      h1 { margin-bottom: 0.5rem; }
      .subtitle { color: #57606a; margin-bottom: 2rem; }
      .card { border: 1px solid #d0d7de; border-radius: 6px; padding: 1.5rem; margin-bottom: 1.5rem; }
      .card h2 { margin-bottom: 1rem; font-size: 1.2rem; }
      .stat { font-size: 2.5rem; font-weight: 700; color: #1a7f37; }
      .stat-label { color: #57606a; font-size: 0.9rem; }
      .links { display: flex; gap: 1rem; margin-bottom: 2rem; }
      .links a { display: inline-block; padding: 0.5rem 1rem; background: #0969da; color: white;
                 text-decoration: none; border-radius: 6px; font-size: 0.9rem; }
      .links a:hover { background: #0860ca; }
      canvas { max-height: 300px; }
      .empty { color: #57606a; font-style: italic; }
    </style>
  </head>
  <body>
    <h1>ruby-dcb Coverage</h1>
    <p class="subtitle">Code coverage tracking for the main branch</p>

    <div class="links">
      <a href="html/index.html">Full Coverage Report</a>
    </div>

    #{if history.any?
        latest = history.last
        <<~CARD
          <div class="card">
            <h2>Current Coverage</h2>
            <div class="stat">#{latest['line_percent']}%</div>
            <div class="stat-label">#{latest['covered_lines']} / #{latest['total_lines']} lines &middot; commit #{latest['commit']}</div>
          </div>
        CARD
      else
        '<div class="card"><p class="empty">No coverage data yet. Coverage will appear after the first push to main.</p></div>'
      end}

    <div class="card">
      <h2>Coverage Over Time</h2>
      #{if history.empty?
          '<p class="empty">Chart will appear after the first push to main.</p>'
        else
          '<canvas id="chart"></canvas>'
        end}
    </div>

    <script>
      const history = #{history.to_json};
      if (history.length >= 1) {
        const ctx = document.getElementById('chart').getContext('2d');
        new Chart(ctx, {
          type: 'line',
          data: {
            labels: history.map(e => e.commit),
            datasets: [{
              label: 'Line Coverage %',
              data: history.map(e => e.line_percent),
              borderColor: '#1a7f37',
              backgroundColor: 'rgba(26, 127, 55, 0.1)',
              fill: true,
              tension: 0.3,
              pointRadius: 4,
              pointHoverRadius: 6
            }]
          },
          options: {
            responsive: true,
            scales: {
              y: { min: Math.max(0, Math.min(...history.map(e => e.line_percent)) - 5),
                   max: 100,
                   ticks: { callback: v => v + '%' } },
              x: { title: { display: true, text: 'Commit' } }
            },
            plugins: {
              tooltip: {
                callbacks: {
                  title: (items) => {
                    const i = items[0].dataIndex;
                    return history[i].timestamp.replace('T', ' ').replace('Z', ' UTC');
                  },
                  label: (item) => `${item.raw}% (${history[item.dataIndex].covered_lines}/${history[item.dataIndex].total_lines} lines)`
                }
              }
            }
          }
        });
      }
    </script>
  </body>
  </html>
HTML

File.write(File.join(output_dir, "index.html"), html)
puts "Generated #{output_dir}/index.html"
