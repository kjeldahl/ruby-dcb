require_relative "../test_helper"
require "dcb_event_store/web"

class TestWebModule < Minitest::Test
  def teardown
    DcbEventStore::Web.connection = nil
  end

  def test_returns_a_plain_connection
    conn = Object.new
    DcbEventStore::Web.connection = conn
    assert_same conn, DcbEventStore::Web.connection
  end

  def test_calls_a_callable_connection_provider
    conn = Object.new
    DcbEventStore::Web.connection = -> { conn }
    assert_same conn, DcbEventStore::Web.connection
  end

  def test_nil_when_unset_and_no_active_record
    DcbEventStore::Web.connection = nil
    assert_nil DcbEventStore::Web.connection
  end

  def test_falls_back_to_active_record_connection
    raw = Object.new
    ar_connection = Object.new
    ar_connection.define_singleton_method(:raw_connection) { raw }
    base = Class.new
    base.define_singleton_method(:connection) { ar_connection }
    active_record = Module.new
    active_record.const_set(:Base, base)
    Object.const_set(:ActiveRecord, active_record)

    DcbEventStore::Web.connection = nil
    assert_same raw, DcbEventStore::Web.connection
  ensure
    Object.send(:remove_const, :ActiveRecord)
  end
end
