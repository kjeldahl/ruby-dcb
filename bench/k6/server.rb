#!/usr/bin/env ruby
# frozen_string_literal: true

# HTTP adapter for the dcb.events k6 conformance/benchmark suite
# (libraries/benchmark in github.com/dcb-events/dcb-events.github.io).
#
# Speaks the suite's default protocol (adapters/http_default.js):
#
#   GET  /read?query=<json>[&options=<json>]
#        query   {"items":[{"types":[..],"tags":[..]}, ..]}  (no items = all)
#        options {"from":n,"limit":n,"backwards":bool}       from is inclusive
#        -> 200 [{"type":..,"tags":[..],"data":..,"position":n}, ..]
#
#   POST /append  {"events":[{"type":..,"tags":[..],"data":".."}],
#                  "condition":{"failIfEventsMatch":<query>,"after":n}}
#        -> 200 {"durationInMicroseconds":n,"appendConditionFailed":bool}
#
# Every request goes through the public store API (read / read_from / append),
# so the suite exercises the gem as an application would. The store is picked
# by DCB_BACKEND like the examples (postgres, sqlite, memory) and starts empty.
# Each Puma thread opens its own connection: a connection belongs to one store.
# PUMA_WORKERS (default: one per core) and PUMA_THREADS (default 16) size it.
#
#   bundle config set --local with bench && bundle install
#   DCB_BACKEND=sqlite bundle exec ruby bench/k6/server.rb   # PORT=3000
#
# bench/k6/run.sh starts it and runs the suite against it.

require_relative "../../examples/support/backend"
require "etc"
require "json"
require "uri"
require "puma"
require "puma/configuration"
require "puma/launcher"

module Bench
  class K6Adapter
    JSON_HEADERS = { "content-type" => "application/json" }.freeze

    # +connect+ returns a fresh store; called once per server thread.
    def initialize(&connect)
      @connect = connect
    end

    def call(env)
      case [env["REQUEST_METHOD"], env["PATH_INFO"]]
      in ["GET", "/read"] then read(URI.decode_www_form(env["QUERY_STRING"].to_s).to_h)
      in ["POST", "/append"] then append(JSON.parse(env["rack.input"].read))
      else [404, JSON_HEADERS, [JSON.generate(error: "not found")]]
      end
    rescue JSON::ParserError, KeyError, NoMatchingPatternError => e
      [400, JSON_HEADERS, [JSON.generate(error: e.message)]]
    end

    private

    def store
      Thread.current[:dcb_k6_store] ||= @connect.call
    end

    def read(params)
      query = to_query(JSON.parse(params.fetch("query")))
      options = params["options"] ? JSON.parse(params["options"]) : {}
      read = options["backwards"] ? :read_backwards : :read_forwards
      events = send(read, query, options["from"], options["limit"])

      [200, JSON_HEADERS, [JSON.generate(events.map { |e| to_json_event(e) })]]
    end

    # Lazy: a limited read stops after +limit+ rows. +from+ is inclusive.
    def read_forwards(query, from, limit)
      stream = from ? store.read_from(query, after: from - 1) : store.read(query)
      limit ? stream.first(limit) : stream.to_a
    end

    # The store reads forwards only, so a backwards read scans the matching
    # stream (up to +from+, inclusive) and keeps its tail.
    def read_backwards(query, from, limit)
      stream = store.read(query)
      stream = stream.take_while { |e| e.sequence_position <= from } if from
      tail = stream.to_a.reverse
      limit ? tail.first(limit) : tail
    end

    def append(body)
      events = body.fetch("events").map do |e|
        DcbEventStore::Event.new(type: e.fetch("type"), tags: e.fetch("tags", []), data: e["data"])
      end
      condition = to_condition(body["condition"])

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)
      failed = begin
        store.append(events, condition)
        false
      rescue DcbEventStore::ConditionNotMet
        true
      end
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond) - started

      [200, JSON_HEADERS, [JSON.generate(durationInMicroseconds: duration, appendConditionFailed: failed)]]
    end

    def to_query(json)
      DcbEventStore::Query.new(json.fetch("items").map do |item|
        DcbEventStore::QueryItem.new(event_types: item.fetch("types", []), tags: item.fetch("tags", []))
      end)
    end

    def to_condition(json)
      return nil unless json

      DcbEventStore::AppendCondition.new(
        fail_if_events_match: to_query(json.fetch("failIfEventsMatch")),
        after: json["after"]
      )
    end

    def to_json_event(event)
      { type: event.type, tags: event.tags, data: event.data, position: event.sequence_position }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  port = Integer(ENV.fetch("PORT", "3000"))
  threads = Integer(ENV.fetch("PUMA_THREADS", "16"))
  # One Ruby process holds the GVL for its request parsing, JSON and row
  # mapping, which caps a single process well below what the database can
  # take; forked workers spread that over the cores.
  workers = Integer(ENV.fetch("PUMA_WORKERS", Etc.nprocessors.to_s))

  Examples::Backend.with_session do |session|
    # InMemoryStore is single-threaded and lives in one process.
    threads = workers = 1 if session.name == "memory"
    workers = 0 if workers == 1
    # A connection must not cross a fork: the workers open their own.
    session.disconnect if workers.positive?

    closers = Queue.new
    app = Bench::K6Adapter.new do
      store, closer = session.connect
      closers << closer if closer
      store
    end

    warn "k6 adapter: #{session.name} on :#{port}, #{[workers, 1].max} process(es) x #{threads} threads"
    config = Puma::Configuration.new do |c|
      c.bind "tcp://127.0.0.1:#{port}"
      c.threads threads, threads
      c.workers workers
      c.app app
      c.quiet
    end
    begin
      Puma::Launcher.new(config, log_writer: Puma::LogWriter.stdio).run
    ensure
      closers.pop.call until closers.empty?
    end
  end
end
