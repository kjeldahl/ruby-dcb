require "concurrent"

# DecisionModel.decide under a real race (issue #52): writers on their own
# connections all try to take a seat in a course at once. Every conflict
# means another writer took a seat, so with capacity seats no writer can
# conflict more than capacity times: the default three retries let each one
# end in a seat or in CourseFull, never in ConditionNotMet.
#
# Including classes set @store in setup and define with_own_store, yielding
# a store on a fresh connection to the same database and closing it after.
module ConcurrentDecideContract
  class CourseFull < StandardError
  end

  def test_decide_fills_the_course_exactly_under_contention
    capacity = 3
    writers = 10
    @store.append([DcbEventStore::Event.new(type: "CourseDefined", data: {capacity: capacity}, tags: ["course:c1"])])

    barrier = Concurrent::CyclicBarrier.new(writers)
    results = Concurrent::Array.new
    threads = writers.times.map do |i|
      Thread.new do
        with_own_store do |store|
          barrier.wait
          results << take_seat(store, "s#{i}")
        rescue CourseFull, DcbEventStore::ConditionNotMet => e
          results << e.class
        end
      end
    end
    threads.each { |thread| thread.join(30) }

    assert_equal writers, results.size
    assert_equal capacity, results.count(:seated), results.inspect
    assert_equal writers - capacity, results.count(CourseFull), results.inspect
    seats = @store.read(DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: ["StudentSubscribed"])]))
    assert_equal capacity, seats.count
  end

  private

  def take_seat(store, student)
    DcbEventStore::DecisionModel.decide(store, capacity: seat_projection("CourseDefined") { |_, e| e.data[:capacity] },
                                               taken: seat_projection("StudentSubscribed") { |n, _| n + 1 }) do |states|
      raise CourseFull if states[:taken] >= states[:capacity]

      [DcbEventStore::Event.new(type: "StudentSubscribed", tags: ["course:c1", "student:#{student}"])]
    end
    :seated
  end

  def seat_projection(type, &handler)
    DcbEventStore::Projection.new(
      initial_state: 0, handlers: { type => handler },
      query: DcbEventStore::Query.new([DcbEventStore::QueryItem.new(event_types: [type], tags: ["course:c1"])])
    )
  end
end
