require_relative "../test_helper"
require_relative "../support/sqlite_database"
require_relative "../../lib/dcb_event_store/cli"
require "open3"
require "stringio"
require "rbconfig"

# The dcb_events command, run in process against SQLite files (the
# PostgreSQL path differs only in how the connection is opened), plus one
# run of the real executable.
class TestCli < Minitest::Test
  cover "DcbEventStore::CLI*"

  include SqliteDatabaseHelper

  BIN = File.expand_path("../../bin/dcb_events", __dir__)

  def setup
    setup_db
    @store.append([
                    DcbEventStore::Event.new(type: "CourseDefined", data: { capacity: 10 }, tags: ["course:c1"]),
                    DcbEventStore::Event.new(type: "StudentRegistered", tags: ["student:s1"]),
                    DcbEventStore::Event.new(type: "CourseDefined", tags: ["course:c2"])
                  ])
    @target_path = File.join(@dir, "target.sqlite3")
  end

  def teardown
    teardown_db
  end

  def cli(*argv, stdin: "")
    out = StringIO.new
    err = StringIO.new
    status = DcbEventStore::CLI.run(argv, stdin: StringIO.new(stdin), stdout: out, stderr: err)
    [status, out.string, err.string]
  end

  def types(jsonl)
    jsonl.lines.map { |line| JSON.parse(line)["type"] }
  end

  def target_events
    db = SqliteDatabaseHelper.connection(@target_path)
    DcbEventStore::SqliteStore.new(db).read(DcbEventStore::Query.all).to_a
  ensure
    db&.close
  end

  # --- export ---

  def test_export_writes_every_event_to_stdout
    status, out, err = cli("export", "-b", "sqlite", "-d", @db_path)

    assert_equal 0, status
    assert_equal %w[CourseDefined StudentRegistered CourseDefined], types(out)
    assert_equal "exported 3 event(s)\n", err
  end

  def test_export_filters
    _, by_type, = cli("export", "--backend", "sqlite", "--database", @db_path, "--type", "StudentRegistered")
    _, by_tag, = cli("export", "-b", "sqlite", "-d", @db_path, "--tag", "course:c2")
    _, after, = cli("export", "-b", "sqlite", "-d", @db_path, "--after", "1", "--type", "CourseDefined")

    assert_equal ["StudentRegistered"], types(by_type)
    assert_equal([["course:c2"]], by_tag.lines.map { |l| JSON.parse(l)["tags"] })
    assert_equal([3], after.lines.map { |l| JSON.parse(l)["sequence_position"] })
  end

  def test_export_to_a_file
    path = File.join(@dir, "out.jsonl")
    status, out, = cli("export", "-b", "sqlite", "-d", @db_path, path)

    assert_equal 0, status
    assert_equal "", out
    assert_equal 3, File.readlines(path).size
  end

  def test_export_refuses_a_missing_sqlite_file
    missing = File.join(@dir, "missing.sqlite3")
    status, _, err = cli("export", "-b", "sqlite", "-d", missing)

    assert_equal 64, status
    assert_equal "dcb_events: no SQLite database at #{missing}\n", err
    refute File.exist?(missing)
  end

  # --- import ---

  def test_import_from_stdin_into_a_new_database
    _, jsonl, = cli("export", "-b", "sqlite", "-d", @db_path)
    status, _, err = cli("import", "-b", "sqlite", "-d", @target_path, "--create-schema", stdin: jsonl)

    assert_equal 0, status
    assert_equal "imported 3 event(s), skipped 0 already stored\n", err
    source = @store.read(DcbEventStore::Query.all).map { |e| e.to_h.except(:sequence_position) }
    assert_equal(source, target_events.map { |e| e.to_h.except(:sequence_position) })
  end

  def test_import_from_a_file_twice_skips_the_second_time
    path = File.join(@dir, "seed.jsonl")
    File.write(path, %({"id":"#{SecureRandom.uuid}","type":"Seeded","tags":["x"]}\n))

    cli("import", "-b", "sqlite", "-d", @target_path, "--create-schema", "--batch-size", "2", path)
    status, _, err = cli("import", "-b", "sqlite", "-d", @target_path, "--batch-size", "0", path)

    assert_equal 0, status
    assert_equal "imported 0 event(s), skipped 1 already stored\n", err
    assert_equal ["Seeded"], target_events.map(&:type)
  end

  def test_import_without_schema_fails_cleanly
    status, _, err = cli("import", "-b", "sqlite", "-d", @target_path, stdin: %({"type":"A"}\n))

    assert_equal 1, status
    assert_match(/\Adcb_events: SQLite3::SQLException: no such table: events/, err)
  end

  def test_import_reports_a_bad_line
    status, _, err = cli("import", "-b", "sqlite", "-d", @db_path, "-", stdin: %({"type":"A"}\n{}\n))

    assert_equal 64, status
    assert_equal %(dcb_events: line 2: missing "type"\n), err
  end

  # --- options ---

  def test_backend_and_database_default_from_the_environment
    ENV["DCB_BACKEND"] = "sqlite"
    ENV["DATABASE_URL"] = @db_path
    status, out, = cli("export")

    assert_equal 0, status
    assert_equal 3, out.lines.size
  ensure
    ENV.delete("DCB_BACKEND")
    ENV.delete("DATABASE_URL")
  end

  def test_help
    status, out, err = cli("--help")

    assert_equal 0, status
    assert_includes out, "Usage: dcb_events export|import"
    assert_includes out, "--create-schema"
    assert_equal "", err
  end

  def test_usage_errors
    {
      [] => "expected command export or import, got nil",
      ["dump"] => %(expected command export or import, got "dump"),
      ["export", "-d", "x"] => "--backend is required (postgres or sqlite)",
      %w[export -b sqlite] => "--database is required",
      %w[export -b mysql -d x] => "invalid argument: -b mysql",
      %w[export -b sqlite -d x a b] => "unexpected argument(s): b",
      %w[import -b sqlite -d x --batch-size -1] => "invalid argument: --batch-size must be >= 0",
      %w[export --bogus] => "invalid option: --bogus"
    }.each do |argv, message|
      ENV.delete("DCB_BACKEND")
      ENV.delete("DATABASE_URL")
      status, _, err = cli(*argv)
      assert_equal [64, "dcb_events: #{message}\n"], [status, err], argv.inspect
    end
  end

  def test_backend_from_the_environment_is_validated
    ENV["DCB_BACKEND"] = "memory"
    status, _, err = cli("export", "-d", @db_path)

    assert_equal 64, status
    assert_equal %(dcb_events: unknown backend "memory" (expected postgres or sqlite)\n), err
  ensure
    ENV.delete("DCB_BACKEND")
  end

  # --- the executable ---

  def test_executable_round_trip
    exported, err, status = Open3.capture3(RbConfig.ruby, BIN, "export", "-b", "sqlite", "-d", @db_path)
    assert status.success?, err

    _, err, status = Open3.capture3(RbConfig.ruby, BIN, "import", "-b", "sqlite", "-d", @target_path,
                                    "--create-schema", stdin_data: exported)
    assert status.success?, err
    assert_equal 3, target_events.size
  end
end
