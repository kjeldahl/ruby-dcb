require_relative "../test_helper"
require "open3"

# The SQL backends are registered with Kernel#autoload, so requiring the gem
# loads neither backend nor its driver; each one arrives on first reference to
# its constant.
#
# Every case runs in a fresh subprocess: the test suite itself has long since
# loaded both backends, so the loading behavior is only observable from a
# process that starts clean.
class TestAutoload < Minitest::Test
  LIB = File.expand_path("../../lib", __dir__)

  # Makes `require "pg"` and `require "sqlite3"` fail as they would in an
  # application that installed only the other driver -- or neither.
  NO_DRIVERS = <<~RUBY.freeze
    module NoDrivers
      def require(name)
        raise LoadError, "cannot load such file -- \#{name}" if ["pg", "sqlite3"].include?(name)

        super
      end
    end
    Object.prepend(NoDrivers)
  RUBY

  # Helpers the scripts below share: `features` lists the loaded gem files
  # that autoload is meant to keep out, and `report` hands the result back as
  # the subprocess's only output.
  HELPERS = <<~RUBY.freeze
    require "json"

    def features
      pattern = %r{/lib/dcb_event_store/(sql_store|postgres_store|sqlite_store|store)(/|\\.rb$)}
      $LOADED_FEATURES.grep(pattern).map { |f| f.split("/lib/dcb_event_store/").last }.sort
    end

    def report(**result) = puts(JSON.generate(result))
  RUBY

  def test_requiring_the_gem_loads_no_backend
    loaded = run_ruby(<<~RUBY)
      require "dcb_event_store"
      report(
        postgres_autoload: !DcbEventStore.autoload?(:PostgresStore).nil?,
        sqlite_autoload: !DcbEventStore.autoload?(:SqliteStore).nil?,
        loaded: features
      )
    RUBY

    assert loaded["postgres_autoload"], "PostgresStore should still be an autoload"
    assert loaded["sqlite_autoload"], "SqliteStore should still be an autoload"
    assert_empty loaded["loaded"]
  end

  def test_referencing_sqlite_store_loads_only_the_sqlite_backend
    loaded = run_ruby(<<~RUBY)
      require "dcb_event_store"
      DcbEventStore::SqliteStore
      report(loaded: features)
    RUBY

    assert_equal(
      ["sql_store.rb", "sql_store/row_mapper.rb", "sql_store/sql_builder.rb",
       "sql_store/timestamp.rb", "sqlite_store.rb", "sqlite_store/dialect.rb",
       "sqlite_store/schema.rb"],
      loaded["loaded"]
    )
  end

  def test_referencing_the_deprecated_store_alias_loads_the_postgres_backend
    loaded = run_ruby(<<~RUBY)
      require "dcb_event_store"
      Warning[:deprecated] = false
      DcbEventStore::Store
      report(loaded: features)
    RUBY

    assert_includes loaded["loaded"], "postgres_store.rb"
    assert_includes loaded["loaded"], "store.rb"
    refute_includes loaded["loaded"], "sqlite_store.rb"
  end

  # The core carries no driver dependency of its own: with both drivers made
  # unloadable, requiring the gem and using InMemoryStore still works.
  def test_the_gem_loads_without_either_driver
    loaded = run_ruby(<<~RUBY, preamble: NO_DRIVERS)
      require "dcb_event_store"
      DcbEventStore::InMemoryStore.new
      report(loaded: features)
    RUBY

    assert_empty loaded["loaded"]
  end

  private

  def run_ruby(script, preamble: "")
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", LIB, "-e", HELPERS + preamble + script)

    assert_predicate status, :success?, "subprocess failed: #{err}"
    JSON.parse(out)
  end
end
