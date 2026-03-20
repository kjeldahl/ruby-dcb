#!/usr/bin/env ruby
# frozen_string_literal: true

# Course Subscriptions example from https://dcb.events/examples/course-subscriptions
#
# Demonstrates DCB's Dynamic Consistency Boundaries:
#   - Tags connect events to multiple entities (course + student)
#   - A single decision model enforces constraints across entities
#   - Optimistic concurrency via append conditions
#
# Usage: ruby examples/course_subscriptions.rb

require_relative "../lib/dcb_event_store"
require "pg"

module CourseSubscriptions
  MAX_STUDENT_COURSES = 5

  # -- Projections -----------------------------------------------------------

  def self.course_exists(course_id)
    DcbEventStore::Projection.new(
      initial_state: false,
      handlers: {
        "CourseDefined" => ->(_state, _event) { true }
      },
      query: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(event_types: ["CourseDefined"], tags: ["course:#{course_id}"])
      ])
    )
  end

  def self.course_capacity(course_id)
    DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: {
        "CourseDefined"         => ->(_state, event) { event.data[:capacity] },
        "CourseCapacityChanged"  => ->(_state, event) { event.data[:new_capacity] }
      },
      query: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(event_types: ["CourseDefined", "CourseCapacityChanged"], tags: ["course:#{course_id}"])
      ])
    )
  end

  def self.course_subscription_count(course_id)
    DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: {
        "StudentSubscribedToCourse" => ->(state, _event) { state + 1 }
      },
      query: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(event_types: ["StudentSubscribedToCourse"], tags: ["course:#{course_id}"])
      ])
    )
  end

  def self.student_subscription_count(student_id)
    DcbEventStore::Projection.new(
      initial_state: 0,
      handlers: {
        "StudentSubscribedToCourse" => ->(state, _event) { state + 1 }
      },
      query: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(event_types: ["StudentSubscribedToCourse"], tags: ["student:#{student_id}"])
      ])
    )
  end

  def self.student_already_subscribed(student_id, course_id)
    DcbEventStore::Projection.new(
      initial_state: false,
      handlers: {
        "StudentSubscribedToCourse" => ->(_state, _event) { true }
      },
      query: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(event_types: ["StudentSubscribedToCourse"], tags: ["student:#{student_id}", "course:#{course_id}"])
      ])
    )
  end

  # -- Command Handlers ------------------------------------------------------

  def self.define_course(client, course_id:, capacity:)
    result = DcbEventStore::DecisionModel.build(client,
      course_exists: course_exists(course_id)
    )

    raise "Course #{course_id} already exists" if result.states[:course_exists]

    client.append(
      DcbEventStore::Event.new(
        type: "CourseDefined",
        data: { course_id: course_id, capacity: capacity },
        tags: ["course:#{course_id}"]
      ),
      result.append_condition
    )
  end

  def self.change_course_capacity(client, course_id:, new_capacity:)
    result = DcbEventStore::DecisionModel.build(client,
      course_exists: course_exists(course_id),
      capacity:      course_capacity(course_id)
    )

    raise "Course #{course_id} does not exist" unless result.states[:course_exists]
    raise "Capacity is already #{new_capacity}" if result.states[:capacity] == new_capacity

    client.append(
      DcbEventStore::Event.new(
        type: "CourseCapacityChanged",
        data: { course_id: course_id, new_capacity: new_capacity },
        tags: ["course:#{course_id}"]
      ),
      result.append_condition
    )
  end

  def self.subscribe_student(client, student_id:, course_id:)
    result = DcbEventStore::DecisionModel.build(client,
      course_exists:       course_exists(course_id),
      capacity:            course_capacity(course_id),
      course_subscriptions: course_subscription_count(course_id),
      student_subscriptions: student_subscription_count(student_id),
      already_subscribed:  student_already_subscribed(student_id, course_id)
    )

    states = result.states
    raise "Course #{course_id} does not exist"                          unless states[:course_exists]
    raise "Student #{student_id} already subscribed to #{course_id}"    if states[:already_subscribed]
    raise "Course #{course_id} is full (#{states[:capacity]} seats)"    if states[:course_subscriptions] >= states[:capacity]
    raise "Student #{student_id} already enrolled in #{MAX_STUDENT_COURSES} courses" if states[:student_subscriptions] >= MAX_STUDENT_COURSES

    client.append(
      DcbEventStore::Event.new(
        type: "StudentSubscribedToCourse",
        data: { student_id: student_id, course_id: course_id },
        tags: ["student:#{student_id}", "course:#{course_id}"]
      ),
      result.append_condition
    )
  end

  # -- Demo ------------------------------------------------------------------

  def self.run
    conn = PG.connect(dbname: "dcb_event_store_test")
    conn.exec("SET client_min_messages TO warning")
    DcbEventStore::Schema.create!(conn)
    conn.exec("TRUNCATE events RESTART IDENTITY")
    store = DcbEventStore::Store.new(conn)
    client = DcbEventStore::Client.new(store)

    puts "=== Course Subscriptions (DCB Example) ==="
    puts

    # Define two courses
    define_course(client, course_id: "math-101", capacity: 2)
    puts "[ok] Defined math-101 (capacity: 2)"

    define_course(client, course_id: "bio-201", capacity: 3)
    puts "[ok] Defined bio-201 (capacity: 3)"

    # Try defining duplicate
    begin
      define_course(client, course_id: "math-101", capacity: 5)
    rescue => e
      puts "[rejected] #{e.message}"
    end

    puts

    # Subscribe students
    subscribe_student(client, student_id: "alice", course_id: "math-101")
    puts "[ok] Alice -> math-101"

    subscribe_student(client, student_id: "bob", course_id: "math-101")
    puts "[ok] Bob -> math-101"

    # Course full
    begin
      subscribe_student(client, student_id: "charlie", course_id: "math-101")
    rescue => e
      puts "[rejected] #{e.message}"
    end

    # Increase capacity
    change_course_capacity(client, course_id: "math-101", new_capacity: 3)
    puts "[ok] math-101 capacity -> 3"

    # Now Charlie can join
    subscribe_student(client, student_id: "charlie", course_id: "math-101")
    puts "[ok] Charlie -> math-101"

    puts

    # Duplicate subscription
    begin
      subscribe_student(client, student_id: "alice", course_id: "math-101")
    rescue => e
      puts "[rejected] #{e.message}"
    end

    # Hit student limit (5 courses)
    subscribe_student(client, student_id: "alice", course_id: "bio-201")
    puts "[ok] Alice -> bio-201"

    %w[chem-301 hist-401 eng-501].each do |cid|
      define_course(client, course_id: cid, capacity: 10)
      subscribe_student(client, student_id: "alice", course_id: cid)
      puts "[ok] Alice -> #{cid}"
    end

    # Alice at 5 courses, one more should fail
    define_course(client, course_id: "art-601", capacity: 10)
    begin
      subscribe_student(client, student_id: "alice", course_id: "art-601")
    rescue => e
      puts "[rejected] #{e.message}"
    end

    puts
    puts "=== Event Log ==="
    client.read(DcbEventStore::Query.all).each do |e|
      puts "  ##{e.sequence_position} #{e.type} tags=#{e.tags.inspect} data=#{e.data.inspect}"
      puts "    correlation=#{e.correlation_id} causation=#{e.causation_id}"
    end

    puts
    puts "Done. #{client.read(DcbEventStore::Query.all).count} events total."
  ensure
    conn&.close
  end
end

CourseSubscriptions.run if __FILE__ == $0
