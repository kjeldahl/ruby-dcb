#!/usr/bin/env ruby
# frozen_string_literal: true

# Backend factory shared by the examples.
#
# The examples are backend-agnostic: `DCB_BACKEND` picks the store they run
# on, so the same domain code can be exercised against either SQL backend or
# against the in-memory store without a server.
#
#   ruby examples/course_subscriptions.rb                    # postgres (default)
#   DCB_BACKEND=sqlite ruby examples/course_subscriptions.rb
#   DCB_BACKEND=memory ruby examples/course_subscriptions.rb
#
# Every session starts from an empty store: PostgreSQL truncates the shared
# test database (or the one named by DCB_PG_DBNAME), SQLite gets a throwaway file under Dir.tmpdir (override with
# DCB_SQLITE_PATH), and InMemoryStore is empty by construction.
#
# Usage:
#
#   Examples::Backend.with_store { |store| ... }   # store, closed on exit
#   Examples::Backend.with_session { |s| ... }     # s.store, s.connect, s.name

require_relative "../../lib/dcb_event_store"
require "tmpdir"
require "fileutils"

module Examples
  module Backend
    NAMES = %w[postgres sqlite memory].freeze
    # Override with DCB_PG_DBNAME to benchmark on a database the test suite
    # is not truncating at the same time.
    PG_DBNAME = ENV.fetch("DCB_PG_DBNAME", "dcb_event_store_test")

    def self.selected(name = nil)
      name || ENV.fetch("DCB_BACKEND", "postgres")
    end

    # Opens a session on the selected backend. The caller owns it and must
    # call #close (or use .with_store / .with_session).
    def self.open(name = nil)
      case selected(name)
      when "postgres" then PostgresSession.new
      when "sqlite"   then SqliteSession.new
      when "memory"   then MemorySession.new
      else
        raise ArgumentError,
              "unknown DCB_BACKEND #{selected(name).inspect} (expected one of: #{NAMES.join(", ")})"
      end
    end

    def self.with_session(name = nil)
      session = open(name)
      begin
        yield session
      ensure
        session.close
      end
    end

    def self.with_store(name = nil)
      with_session(name) { |session| yield session.store }
    end

    # A session owns the connection an example runs on, plus any extra ones
    # opened for threads or forked processes, and releases them all on #close.
    class Session
      attr_reader :store

      def name
        self.class::NAME
      end

      # The driver handle behind #store (a PG::Connection or an
      # SQLite3::Database), for the few places that need backend-specific SQL.
      # nil for the in-memory store, which has no connection.
      def connection
        nil
      end

      # An independent store on the same database, for a thread or a forked
      # process. Returns [store, closer]; the caller invokes the closer when
      # done with it.
      def connect
        [store, nil]
      end

      def close; end
    end

    class PostgresSession < Session
      NAME = "postgres"

      attr_reader :connection

      def initialize
        super
        require "pg"
        @connection, = self.class.connect_raw
        DcbEventStore::PostgresStore::Schema.create!(@connection)
        @connection.exec("TRUNCATE events RESTART IDENTITY")
        @store = DcbEventStore::PostgresStore.new(@connection)
      end

      # Each connection is independent, so a thread or a forked process just
      # opens its own; the schema is already there.
      def connect
        conn, closer = self.class.connect_raw
        [DcbEventStore::PostgresStore.new(conn), closer]
      end

      def close
        @connection&.close
        @connection = nil
      end

      def self.connect_raw
        conn = PG.connect(dbname: PG_DBNAME)
        conn.exec("SET client_min_messages TO warning")
        [conn, -> { conn.close }]
      end
    end

    class SqliteSession < Session
      NAME = "sqlite"

      attr_reader :connection, :path

      def initialize
        super
        require "sqlite3"
        @path = ENV["DCB_SQLITE_PATH"] || begin
          @dir = Dir.mktmpdir("dcb_event_store_example")
          File.join(@dir, "events.sqlite3")
        end
        @connection = SQLite3::Database.new(@path)
        DcbEventStore::SqliteStore::Schema.drop!(@connection)
        DcbEventStore::SqliteStore::Schema.create!(@connection)
        @store = DcbEventStore::SqliteStore.new(@connection)
      end

      # A second connection on the same file: WAL plus the busy handler let
      # readers and the single writer work side by side.
      def connect
        db = SQLite3::Database.new(@path)
        DcbEventStore::SqliteStore::Schema.configure!(db)
        [DcbEventStore::SqliteStore.new(db), -> { db.close }]
      end

      def close
        @connection&.close
        @connection = nil
        FileUtils.remove_entry(@dir) if @dir
        @dir = nil
      end
    end

    class MemorySession < Session
      NAME = "memory"

      def initialize
        super
        @store = DcbEventStore::InMemoryStore.new
      end
    end
  end
end
