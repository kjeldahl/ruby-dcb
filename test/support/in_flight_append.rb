require "concurrent"

# An append or import caught in flight on PostgreSQL: its write transaction
# stays open, locks held and rows inserted but uncommitted, until the test
# releases it.
module InFlightAppendHelper
  # A store whose write transaction pauses after its block ran: +paused+ is
  # set once it holds its locks and has inserted, and it commits once
  # +release+ is set.
  class PausingStore < DcbEventStore::PostgresStore
    def initialize(conn, paused:, release:, namespace: nil)
      super(conn, namespace: namespace)
      @paused = paused
      @release = release
    end

    private

    def with_write_transaction
      super do
        result = yield
        @paused.set
        @release.wait
        result
      end
    end
  end

  # Starts append(*args) on a paused store over its own connection and
  # returns once it is in flight. Yields a release proc that commits it and
  # returns the append's result; the append is released and its connection
  # closed when the block returns, whatever happened in it.
  def with_in_flight_append(*args, namespace: nil, &)
    with_in_flight_write(->(store) { store.append(*args) }, namespace: namespace, &)
  end

  # #with_in_flight_append for an import(events).
  def with_in_flight_import(events, namespace: nil, &)
    with_in_flight_write(->(store) { store.import(events) }, namespace: namespace, &)
  end

  private

  def with_in_flight_write(write, namespace:)
    paused_at = Concurrent::Event.new
    release = Concurrent::Event.new
    conn = PostgresDatabaseHelper.connection
    thread = Thread.new do
      write.call(PausingStore.new(conn, paused: paused_at, release: release, namespace: namespace))
    end
    deadline = Time.now + 3
    sleep 0.01 while thread.alive? && !paused_at.set? && Time.now < deadline
    thread.value unless thread.alive?
    assert paused_at.set?, "in-flight write never took its locks"

    yield(lambda {
      release.set
      thread.value
    })
  ensure
    release&.set
    thread&.join(5)
    conn&.close
  end
end
