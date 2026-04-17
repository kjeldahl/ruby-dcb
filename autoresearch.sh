#!/bin/bash
set -euo pipefail

cd /Users/jacob/Dev/tries/2026-03-05-ruby-dcb

# Quick syntax check
ruby -c lib/dcb_event_store/decision_model.rb >/dev/null 2>&1

# Run the benchmark focused on DecisionModel.build timing
bundle exec ruby experiments/decision_model_bench.rb