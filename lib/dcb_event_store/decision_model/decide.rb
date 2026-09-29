module DcbEventStore
  module DecisionModel
    DECIDE_EVENT = "decide.dcb".freeze
    DEFAULT_RETRIES = 3
    DEFAULT_BACKOFF = (0.01..0.2)
    SLEEP = ->(seconds) { sleep(seconds) }

    # The DCB write loop with its retry: build the model, let the block decide
    # on its states, append what it returns under the model's condition, and
    # on ConditionNotMet start over from a fresh build (issue #52).
    #
    #   DecisionModel.decide(store, capacity: capacity, subscriptions: count) do |states|
    #     raise CourseFull if states[:subscriptions] >= states[:capacity]
    #     [Event.new(type: "StudentSubscribed", tags: [...])]
    #   end
    #   # => the appended SequencedEvents
    #
    # The block gets the states Hash (as DecisionModel.build returns them) and
    # returns the events to append: an Event, an Array of them, or [] / nil to
    # append nothing (decide then returns []). It runs once per attempt, so it
    # must not have side effects other than its return value.
    #
    # Only ConditionNotMet raised by the append is retried, +retries+ times at
    # most (so up to retries + 1 builds); once they run out it is re-raised.
    # Anything else, the block's own errors included, propagates at once.
    # Between attempts it sleeps per +backoff+: a Range (a uniformly random
    # delay in it, the jitter spreading out writers that collided), a fixed
    # Numeric, a callable taking the attempt number that just failed (1 for
    # the first) and returning seconds, or nil / 0 for no pause. +sleeper+
    # is what sleeps (a test seam).
    #
    # +snapshots+ is passed through to DecisionModel.build. It and +retries+,
    # +backoff+, +sleeper+ cannot name projections.
    #
    # Published as one "decide.dcb" event: projections:, attempts: (builds
    # run, so far on error), appended_count:; each build's own
    # "decision_model.dcb" carries attempt:.
    def self.decide(store, snapshots: nil, retries: DEFAULT_RETRIES, backoff: DEFAULT_BACKOFF,
                    sleeper: SLEEP, **projections) # rubocop:disable Metrics/ParameterLists
      raise ArgumentError, "a decision block is required" unless block_given?

      validate_decide_options!(retries, backoff)

      DcbEventStore.instrumentation.instrument(DECIDE_EVENT, projections: projections.keys) do |payload|
        (1..).each do |attempt|
          payload[:attempts] = attempt
          result = build_model(store, snapshots, projections, attempt: attempt)
          events = Array(yield(result.states))
          appended = append_unless_conflict(store, events, result.append_condition, attempt <= retries)
          if appended
            payload[:appended_count] = appended.size
            break appended
          end

          pause(sleeper, backoff_delay(backoff, attempt))
        end
      end
    end

    def self.validate_decide_options!(retries, backoff)
      unless Integer === retries && !retries.negative? # rubocop:disable Style/CaseEquality
        raise ArgumentError, "retries must be a non-negative Integer, got #{retries.inspect}"
      end

      case backoff
      when nil, Range, Numeric then nil
      else
        return if backoff.respond_to?(:call)

        raise ArgumentError, "backoff must be a Range, a Numeric, a callable or nil, got #{backoff.inspect}"
      end
    end

    # The appended events ([] when there were none to append), or nil for a
    # conflict that may be retried.
    def self.append_unless_conflict(store, events, condition, retryable)
      return [] if events.empty?

      store.append(events, condition)
    rescue ConditionNotMet
      raise unless retryable
    end

    def self.backoff_delay(backoff, attempt)
      case backoff
      when Range then rand(backoff)
      when Numeric, nil then backoff
      else backoff.call(attempt)
      end
    end

    def self.pause(sleeper, delay)
      sleeper.call(delay) if delay&.positive?
    end

    private_class_method :validate_decide_options!, :append_unless_conflict, :backoff_delay, :pause
  end
end
