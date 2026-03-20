# frozen_string_literal: true

require_relative "../lib/dcb_event_store"
require "json"
require "time"

module Experiments
  # Wraps Store with per-phase timing instrumentation.
  # Collects timings into an array for later analysis.
  class InstrumentedStore < DcbEventStore::Store
    attr_reader :timings

    def initialize(conn, upcaster: nil)
      super
      @timings = []
    end

    def append(events, condition = nil)
      events = Array(events)
      timing = {}

      with_transaction do
        timing[:lock_wait] = measure { @conn.exec("SELECT pg_advisory_xact_lock($1)", [APPEND_LOCK_KEY]) }

        if condition
          timing[:condition_check] = measure { check_condition!(condition) }
        end

        timing[:insert] = measure do
          @sequenced = events.filter_map do |event|
            result = @conn.exec_params(
              <<~SQL,
                INSERT INTO events (event_id, type, data, tags, causation_id, correlation_id, schema_version)
                VALUES ($1, $2, $3::jsonb, $4::text[], $5, $6, $7)
                ON CONFLICT (event_id) DO NOTHING
                RETURNING sequence_position, created_at
              SQL
              [event.id, event.type, JSON.generate(event.data), "{#{event.tags.join(",")}}",
               event.causation_id, event.correlation_id, 1]
            )
            next nil if result.ntuples.zero?

            row = result[0]
            DcbEventStore::SequencedEvent.new(
              sequence_position: row["sequence_position"].to_i,
              type: event.type,
              data: event.data,
              tags: event.tags,
              created_at: Time.parse(row["created_at"]),
              id: event.id,
              causation_id: event.causation_id,
              correlation_id: event.correlation_id,
              schema_version: 1
            )
          end
        end

        timing[:notify] = measure do
          notify_position = @sequenced.last&.sequence_position
          @conn.exec("NOTIFY events_appended, '#{notify_position}'") if notify_position
        end

        @sequenced
      end

      timing[:total] = timing.values.sum
      @timings << timing
      @sequenced
    end

    def clear_timings!
      @timings.clear
    end

    def timing_summary
      return {} if @timings.empty?

      keys = @timings.first.keys
      keys.each_with_object({}) do |key, summary|
        values = @timings.map { |t| t[key] }.compact.sort
        next if values.empty?

        summary[key] = {
          p50: percentile(values, 50),
          p90: percentile(values, 90),
          p99: percentile(values, 99),
          stddev: stddev(values),
          n: values.size
        }
      end
    end

    private

    def measure
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    end

    def percentile(sorted, p)
      return sorted[0] if sorted.size == 1
      rank = p / 100.0 * (sorted.size - 1)
      low = rank.floor
      high = rank.ceil
      low == high ? sorted[low] : sorted[low] + (rank - low) * (sorted[high] - sorted[low])
    end

    def stddev(values)
      avg = values.sum / values.size.to_f
      variance = values.sum { |v| (v - avg)**2 } / values.size
      Math.sqrt(variance)
    end
  end

  # Wraps DecisionModel.build with timing
  module InstrumentedDecisionModel
    def self.timings
      @timings ||= []
    end

    def self.clear_timings!
      @timings&.clear
    end

    def self.build(store, **projections)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = DcbEventStore::DecisionModel.build(store, **projections)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      timings << { dm_read: elapsed }
      result
    end

    def self.timing_summary
      return {} if timings.empty?

      values = timings.map { |t| t[:dm_read] }.sort
      {
        dm_read: {
          p50: percentile(values, 50),
          p90: percentile(values, 90),
          p99: percentile(values, 99),
          stddev: stddev(values),
          n: values.size
        }
      }
    end

    def self.percentile(sorted, p)
      return sorted[0] if sorted.size == 1
      rank = p / 100.0 * (sorted.size - 1)
      low = rank.floor
      high = rank.ceil
      low == high ? sorted[low] : sorted[low] + (rank - low) * (sorted[high] - sorted[low])
    end

    def self.stddev(values)
      avg = values.sum / values.size.to_f
      variance = values.sum { |v| (v - avg)**2 } / values.size
      Math.sqrt(variance)
    end
  end
end
