require_relative "../test_helper"

# The pre-rename names (Store, Schema, PgArrayCodec) still resolve to the
# renamed constants, and Ruby flags them as deprecated on use.
#
# Every reference goes through #with_warnings: the suite runs with Ruby's
# deprecation category enabled, so a bare reference would print a warning line
# of its own.
class TestDeprecatedAliases < Minitest::Test
  # Collects Ruby's own warnings while a block runs. Warning.warn is a
  # singleton method, so the capture is prepended once and delegates to the
  # real implementation whenever no collector is installed.
  module WarningCapture
    class << self
      attr_accessor :collected
    end

    def warn(message, category: nil)
      collected = WarningCapture.collected
      return super if collected.nil?

      collected << message
      nil
    end
  end
  Warning.singleton_class.prepend(WarningCapture)

  def test_store_is_the_postgres_store_and_warns
    store, warnings = with_warnings { DcbEventStore::Store }

    assert_same DcbEventStore::PostgresStore, store
    assert_equal 1, warnings.size
    assert_match(/constant DcbEventStore::Store is deprecated/, warnings.first)
  end

  def test_schema_is_the_postgres_schema_and_warns
    schema, warnings = with_warnings { DcbEventStore::Schema }

    assert_same DcbEventStore::PostgresStore::Schema, schema
    assert_equal 1, warnings.size
    assert_match(/constant DcbEventStore::Schema is deprecated/, warnings.first)
  end

  def test_pg_array_codec_is_the_postgres_array_codec_and_warns
    codec, warnings = with_warnings { DcbEventStore::PgArrayCodec }

    assert_same DcbEventStore::PostgresStore::ArrayCodec, codec
    assert_equal 1, warnings.size
    assert_match(/constant DcbEventStore::PgArrayCodec is deprecated/, warnings.first)
  end

  # Store::LockKeys and Store::SqlBuilder were reachable through the old name,
  # so they have to stay reachable through the alias.
  def test_nested_constants_resolve_through_the_alias
    nested, = with_warnings { [DcbEventStore::Store::LockKeys, DcbEventStore::Store::SqlBuilder] }

    assert_equal [DcbEventStore::PostgresStore::LockKeys, DcbEventStore::SqlStore::SqlBuilder], nested
  end

  # Ruby's deprecation category can be switched off, and then an application
  # that has not moved over yet is not written to on every access.
  def test_aliases_are_silent_when_deprecation_warnings_are_disabled
    _, warnings = with_warnings(deprecated: false) { DcbEventStore::Store }

    assert_empty warnings
  end

  private

  def with_warnings(deprecated: true)
    was = Warning[:deprecated]
    Warning[:deprecated] = deprecated
    WarningCapture.collected = []
    [yield, WarningCapture.collected]
  ensure
    WarningCapture.collected = nil
    Warning[:deprecated] = was
  end
end
