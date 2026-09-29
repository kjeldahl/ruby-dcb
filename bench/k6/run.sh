#!/usr/bin/env bash
# Runs the dcb.events k6 suite against bench/k6/server.rb, one fresh server
# (and so one empty store) per backend and test.
#
#   bench/k6/run.sh                      # postgres + sqlite, all three tests
#   BACKENDS=sqlite TESTS=consistency bench/k6/run.sh
#
# Needs k6 (>= 1.0, runs the suite's TypeScript as is) on PATH or in $K6, and
# for the monotonic test a redis server at $REDIS_DSN (default
# redis://localhost:6379); without one that test is skipped. PostgreSQL is the
# examples' database (DCB_PG_DBNAME, default dcb_event_store_test).
#
# Results: one k6 summary export (and server log) per run in bench/k6/results/,
# k6's own report on stderr, then summarize.rb prints a markdown table to stdout and exits non-zero if a run is missing,
# a request failed or a conformance check failed.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
suite_repo="https://github.com/dcb-events/dcb-events.github.io.git"
suite_ref="${SUITE_REF:-6a47fc51312d4d6da93688e11d029e40e1d7eb5d}"
suite="$here/.suite"
results="$here/results"
k6="${K6:-k6}"
port="${PORT:-3000}"
backends="${BACKENDS:-postgres sqlite}"
tests="${TESTS:-consistency monotonic parallel-writes}"
redis_dsn="${REDIS_DSN:-redis://localhost:6379}"

if [ "$(git -C "$suite" rev-parse HEAD 2>/dev/null)" != "$suite_ref" ]; then
  rm -rf "$suite"
  git init -q "$suite"
  git -C "$suite" remote add origin "$suite_repo"
  git -C "$suite" sparse-checkout set libraries/benchmark
  git -C "$suite" fetch -q --depth 1 --filter=blob:none origin "$suite_ref"
  git -C "$suite" checkout -q FETCH_HEAD
fi

redis_up() {
  command -v redis-cli >/dev/null && redis-cli -u "$redis_dsn" ping >/dev/null 2>&1
}

server_pid=""
stop_server() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
  fi
}
trap stop_server EXIT

mkdir -p "$results"
exports=()
for backend in $backends; do
  for test in $tests; do
    extra=()
    if [ "$test" = monotonic ]; then
      if ! redis_up; then
        echo "skip $backend/$test: no redis at $redis_dsn" >&2
        continue
      fi
      extra=(-e "REDIS_DSN=$redis_dsn")
    fi

    rm -f "$results/$backend-$test.json"
    exports+=("$results/$backend-$test.json")
    BUNDLE_GEMFILE="$root/Gemfile" DCB_BACKEND="$backend" PORT="$port" bundle exec \
      ruby "$here/server.rb" >"$results/$backend-$test.log" 2>&1 &
    server_pid=$!
    for _ in $(seq 1 50); do
      curl -sf -o /dev/null -G "http://127.0.0.1:$port/read" --data-urlencode 'query={"items":[]}' && break
      sleep 0.2
    done

    echo "== $backend / $test" >&2
    (cd "$suite/libraries/benchmark" &&
      "$k6" run --quiet --summary-export "$results/$backend-$test.json" \
        -e "BASE_URI=http://127.0.0.1:$port" "${extra[@]}" "dcb-$test.ts" >&2) || true
    stop_server
  done
done

ruby "$here/summarize.rb" "${exports[@]}"
