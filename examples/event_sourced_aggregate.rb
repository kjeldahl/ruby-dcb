#!/usr/bin/env ruby
# frozen_string_literal: true

# Event-Sourced Aggregate example from https://dcb.events/examples/event-sourced-aggregate/
#
# Shows how a traditional aggregate (Course) maps onto DCB. Instead of
# stream-based optimistic locking, the aggregate uses tag-based queries
# and append conditions for consistency.
#
# Usage: ruby examples/event_sourced_aggregate.rb

require_relative "../lib/dcb_event_store"
require "pg"

module EventSourcedAggregate
  class CourseAggregate
    attr_reader :id, :capacity, :subscriptions, :exists

    def initialize(id)
      @id = id
      @capacity = 0
      @subscriptions = 0
      @exists = false
      @recorded_events = []
    end

    def define(capacity:)
      raise "Course #{@id} already exists" if @exists
      record("CourseDefined", { course_id: @id, capacity: capacity })
    end

    def change_capacity(new_capacity:)
      raise "Course #{@id} does not exist" unless @exists
      raise "Capacity is already #{new_capacity}" if @capacity == new_capacity
      raise "Cannot reduce below #{@subscriptions} active subscriptions" if new_capacity < @subscriptions
      record("CourseCapacityChanged", { course_id: @id, new_capacity: new_capacity })
    end

    def subscribe_student(student_id:)
      raise "Course #{@id} does not exist" unless @exists
      raise "Course #{@id} is full (#{@capacity} seats)" if @subscriptions >= @capacity
      record("StudentSubscribedToCourse", { course_id: @id, student_id: student_id })
    end

    def recorded_events
      @recorded_events
    end

    # Apply an event to update internal state (used during rehydration and recording)
    def apply(event_type, data)
      case event_type
      when "CourseDefined"
        @exists = true
        @capacity = data[:capacity]
      when "CourseCapacityChanged"
        @capacity = data[:new_capacity]
      when "StudentSubscribedToCourse"
        @subscriptions += 1
      end
    end

    private

    def record(type, data)
      apply(type, data)
      @recorded_events << DcbEventStore::Event.new(
        type: type,
        data: data,
        tags: ["course:#{@id}"]
      )
    end
  end

  # -- Repository (DCB-backed) ------------------------------------------------

  def self.load_aggregate(client, course_id)
    aggregate = CourseAggregate.new(course_id)
    query = DcbEventStore::Query.new([
      DcbEventStore::QueryItem.new(
        event_types: %w[CourseDefined CourseCapacityChanged StudentSubscribedToCourse],
        tags: ["course:#{course_id}"]
      )
    ])

    events = client.read(query).to_a
    events.each { |e| aggregate.apply(e.type, e.data) }

    max_pos = events.map(&:sequence_position).max
    condition = DcbEventStore::AppendCondition.new(
      fail_if_events_match: query,
      after: max_pos
    )

    [aggregate, condition]
  end

  def self.save_aggregate(client, aggregate, condition)
    return if aggregate.recorded_events.empty?
    client.append(aggregate.recorded_events, condition)
  end

  # -- Demo ------------------------------------------------------------------

  def self.run
    conn = PG.connect(dbname: "dcb_event_store_test")
    conn.exec("SET client_min_messages TO warning")
    DcbEventStore::Schema.create!(conn)
    conn.exec("TRUNCATE events RESTART IDENTITY")
    store = DcbEventStore::Store.new(conn)
    client = DcbEventStore::Client.new(store)

    puts "=== Event-Sourced Aggregate (DCB Example) ==="
    puts

    # Define a course
    agg, cond = load_aggregate(client, "math-101")
    agg.define(capacity: 2)
    save_aggregate(client, agg, cond)
    puts "[ok] Defined math-101 (capacity: 2)"

    # Subscribe students
    agg, cond = load_aggregate(client, "math-101")
    agg.subscribe_student(student_id: "alice")
    agg.subscribe_student(student_id: "bob")
    save_aggregate(client, agg, cond)
    puts "[ok] Subscribed alice + bob"

    # Full -- reject
    agg, cond = load_aggregate(client, "math-101")
    begin
      agg.subscribe_student(student_id: "charlie")
    rescue => e
      puts "[rejected] #{e.message}"
    end

    # Change capacity
    agg, cond = load_aggregate(client, "math-101")
    agg.change_capacity(new_capacity: 3)
    save_aggregate(client, agg, cond)
    puts "[ok] Capacity -> 3"

    # Can't reduce below active subscriptions
    agg, cond = load_aggregate(client, "math-101")
    begin
      agg.change_capacity(new_capacity: 1)
    rescue => e
      puts "[rejected] #{e.message}"
    end

    # Now charlie can join
    agg, cond = load_aggregate(client, "math-101")
    agg.subscribe_student(student_id: "charlie")
    save_aggregate(client, agg, cond)
    puts "[ok] Subscribed charlie"

    # Concurrent conflict
    puts
    puts "--- Concurrent conflict ---"
    agg1, cond1 = load_aggregate(client, "math-101")
    agg2, cond2 = load_aggregate(client, "math-101")

    agg1.change_capacity(new_capacity: 5)
    save_aggregate(client, agg1, cond1)
    puts "[ok] First: capacity -> 5"

    agg2.change_capacity(new_capacity: 10)
    begin
      save_aggregate(client, agg2, cond2)
    rescue DcbEventStore::ConditionNotMet => e
      puts "[rejected] Second: #{e.message} (stale read)"
    end

    puts
    puts "=== Event Log ==="
    client.read(DcbEventStore::Query.all).each do |e|
      puts "  ##{e.sequence_position} #{e.type} data=#{e.data.inspect}"
    end

    puts
    puts "Done. #{client.read(DcbEventStore::Query.all).count} events total."
  ensure
    conn&.close
  end
end

EventSourcedAggregate.run if __FILE__ == $0
