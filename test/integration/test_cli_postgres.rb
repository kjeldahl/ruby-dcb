require_relative "../test_helper"
require_relative "../support/postgres_database"
require_relative "../../lib/dcb_event_store/cli"
require "stringio"

# The dcb_events command's PostgreSQL connection handling; everything else
# about the command is covered against SQLite in test/sqlite/test_cli.rb.
class TestCliPostgres < Minitest::Test
  cover "DcbEventStore::CLI*"

  include PostgresDatabaseHelper

  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  def cli(*argv, stdin: "")
    err = StringIO.new
    out = StringIO.new
    status = DcbEventStore::CLI.run(argv, stdin: StringIO.new(stdin), stdout: out, stderr: err)
    [status, out.string, err.string]
  end

  def test_import_then_export_by_dbname
    seed = %({"id":"#{SecureRandom.uuid}","type":"A","tags":["x"],"schema_version":2}\n)
    status, _, err = cli("import", "-b", "postgres", "-d", "dcb_event_store_test", "--create-schema", stdin: seed)
    assert_equal [0, "imported 1 event(s), skipped 0 already stored\n"], [status, err]

    status, out, = cli("export", "-b", "postgres", "-d", "dcb_event_store_test")
    assert_equal 0, status
    assert_equal([["A", 2]], out.lines.drop(1).map { |l| JSON.parse(l).values_at("type", "schema_version") })
  end

  def test_conninfo_string_and_url
    @store.append([DcbEventStore::Event.new(type: "A")])
    host = ENV.fetch("PGHOST", nil)
    url = host && !host.empty? && !host.start_with?("/") ? "postgres://#{host}/dcb_event_store_test" : nil

    ["dbname=dcb_event_store_test", url].compact.each do |database|
      status, out, err = cli("export", "-b", "postgres", "-d", database)
      assert_equal [0, 2], [status, out.lines.size], err
    end
  end

  def test_connection_failure_is_reported
    status, _, err = cli("export", "-b", "postgres", "-d", "dcb_no_such_database_#{Process.pid}")

    assert_equal 1, status
    assert_match(/\Adcb_events: PG::ConnectionBad: /, err)
  end
end
