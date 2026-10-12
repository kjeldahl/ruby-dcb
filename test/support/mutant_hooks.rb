# Mutant hooks (wired in .mutant.yml under `hooks:`).
#
# Each mutant worker is a forked process that runs many mutations' tests over
# its lifetime. When they all share one database, their per-test `TRUNCATE` and
# tag advisory-locks collide: a mutation that a test would normally kill slips
# past as a spurious survivor, and the timing-sensitive subscribe tests trip the
# mutation timeout. Binding every worker to its own database removes the race.
#
# The worker-start hooks fire once per worker child, in that child, before it
# dispatches any test, and carry the worker's index. Both the test-collection
# and mutation phases get their own hook, so either pool's workers are isolated.
require_relative "postgres_database"

%i[
  test_worker_process_start
  mutation_worker_process_start
].each do |hook|
  hooks.register(hook) do |index:|
    PostgresDatabaseHelper.prepare_worker(database: "dcb_event_store_test_w#{index}")
  end
end
