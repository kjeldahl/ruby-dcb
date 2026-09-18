require_relative "../test_helper"
require "rails"
require "dcb_event_store/railtie"
require "open3"
require "stringio"

# The railtie is what makes a Rails application log store operations without
# writing an initializer: it swaps the instrumentation engine for the
# ActiveSupport one and attaches RailsLogSubscriber.
#
# Its initializer body is one call to .install, so the wiring is exercised
# here directly against a config double -- booting a real application would
# only add Rails' own initializer chain to the test.
class TestRailtie < Minitest::Test
  cover "DcbEventStore::Railtie*"

  LIB = File.expand_path("../../lib", __dir__)

  def setup
    @engine = DcbEventStore.instrumentation
    @logger_was = Rails.logger
    @io = StringIO.new
    Rails.logger = Logger.new(@io)
    @installed = []
  end

  def teardown
    @installed.each do |options|
      DcbEventStore.instrumentation.unsubscribe(options[:log_subscription])
    end
    DcbEventStore.instrumentation = @engine
    Rails.logger = @logger_was
  end

  # A stand-in for Rails.application: everything .install reads is config.
  def build_app(colorize_logging: true, **options)
    config = ActiveSupport::OrderedOptions.new
    config.colorize_logging = colorize_logging
    config.dcb_event_store = ActiveSupport::OrderedOptions.new.update(options)
    Struct.new(:config).new(config)
  end

  def install(app)
    DcbEventStore::Railtie.install(app).tap { @installed << app.config.dcb_event_store }
  end

  def append(type: "Deposited")
    DcbEventStore::InMemoryStore.new.append(DcbEventStore::Event.new(type: type))
  end

  # Strips ANSI escape sequences so assertions can target the visible text.
  def visible(string)
    string.gsub(/\e\[[0-9;]*m/, "")
  end

  def test_install_routes_events_through_active_support_and_the_rails_logger
    app = build_app
    install(app)

    assert_instance_of DcbEventStore::ActiveSupportInstrumentation, DcbEventStore.instrumentation

    names = []
    subscription = ActiveSupport::Notifications.subscribe(/\.dcb\z/) { |name, *| names << name }
    append
    ActiveSupport::Notifications.unsubscribe(subscription)

    assert_equal ["append.dcb"], names
    assert_includes visible(@io.string), "DCB Append"
    assert_includes visible(@io.string), "event_count=1 event_types=[Deposited]"
  end

  def test_install_exposes_the_attached_subscriber_and_its_subscription
    app = build_app
    subscriber = install(app)
    options = app.config.dcb_event_store

    assert_instance_of DcbEventStore::RailsLogSubscriber, subscriber
    assert_same subscriber, options[:log_subscriber]

    DcbEventStore.instrumentation.unsubscribe(options[:log_subscription])
    append

    assert_empty @io.string
  end

  def test_log_false_leaves_the_engine_swapped_but_logs_nothing
    app = build_app(log: false)

    assert_nil install(app)
    assert_instance_of DcbEventStore::ActiveSupportInstrumentation, DcbEventStore.instrumentation

    append

    assert_empty @io.string
    assert_nil app.config.dcb_event_store[:log_subscriber]
  end

  def test_standalone_keeps_the_engine_the_application_already_assigned
    engine = DcbEventStore::Notifications.new
    DcbEventStore.instrumentation = engine

    install(build_app(instrumentation: :standalone))

    assert_same engine, DcbEventStore.instrumentation

    append

    assert_includes visible(@io.string), "DCB Append"
  end

  def test_unknown_instrumentation_setting_is_rejected_by_name
    error = assert_raises(ArgumentError) { install(build_app(instrumentation: :activesupport)) }

    assert_includes error.message, ":activesupport"
    assert_includes error.message, ":active_support or :standalone"
  end

  def test_logger_and_pattern_are_configurable
    io = StringIO.new
    install(build_app(logger: Logger.new(io), pattern: "read.dcb"))

    append
    DcbEventStore::InMemoryStore.new.read(DcbEventStore::Query.all).to_a

    assert_empty @io.string, "the configured logger should be used, not Rails.logger"
    refute_includes visible(io.string), "DCB Append"
    assert_includes visible(io.string), "DCB Read"
  end

  def test_colorize_follows_rails_logging_unless_set
    install(build_app(colorize_logging: false))
    append

    assert_equal @io.string, visible(@io.string)
  end

  def test_colorize_follows_rails_logging_when_it_is_on
    install(build_app(colorize_logging: true))
    append

    refute_equal @io.string, visible(@io.string)
  end

  def test_colorize_false_wins_over_rails_logging
    install(build_app(colorize_logging: true, colorize: false))
    append

    assert_equal @io.string, visible(@io.string)
  end

  def test_colorize_true_wins_over_rails_logging
    install(build_app(colorize_logging: false, colorize: true))
    append

    refute_equal @io.string, visible(@io.string)
  end

  # The default pattern is the gem's own events: with the engine swapped,
  # an unfiltered subscriber would render every ActiveSupport notification
  # the application makes -- the whole SQL log, twice.
  def test_only_dcb_events_are_logged_by_default
    install(build_app)

    ActiveSupport::Notifications.instrument("sql.active_record", name: "User Load") { nil }

    assert_empty @io.string

    append

    assert_includes visible(@io.string), "DCB Append"
  end

  # What makes any of this automatic: Rails runs the initializer at boot,
  # after :initialize_logger so Rails.logger is the application's own.
  def test_the_railtie_registers_one_initializer_that_installs_the_wiring
    initializer = DcbEventStore::Railtie.initializers
                                        .find { |i| i.name == "dcb_event_store.instrumentation" }

    refute_nil initializer, "the railtie should register dcb_event_store.instrumentation"
    assert_equal :initialize_logger, initializer.after

    app = build_app
    initializer.run(app)
    @installed << app.config.dcb_event_store

    assert_instance_of DcbEventStore::ActiveSupportInstrumentation, DcbEventStore.instrumentation
    assert_instance_of DcbEventStore::RailsLogSubscriber, app.config.dcb_event_store[:log_subscriber]
  end

  # One entry point: the helpers below it are internal, so an application
  # cannot come to depend on their shape.
  def test_install_is_the_only_public_entry_point
    assert_respond_to DcbEventStore::Railtie, :install
    %i[install_engine install_log_subscriber colorize?].each do |helper|
      refute_respond_to DcbEventStore::Railtie, helper
    end
  end

  # The gem carries no Rails dependency: the railtie file is required only
  # when Rails is already loaded, which is observable from a clean process.
  def test_the_railtie_loads_only_inside_a_rails_process
    refute railtie_defined?('require "dcb_event_store"'),
           "requiring the gem outside Rails should not load the railtie"
    assert railtie_defined?('require "rails"; require "dcb_event_store"')
  end

  private

  def railtie_defined?(script)
    out, err, status = Open3.capture3(
      RbConfig.ruby, "-I", LIB, "-e",
      "#{script}; print DcbEventStore.const_defined?(:Railtie, false)"
    )

    assert_predicate status, :success?, "subprocess failed: #{err}"
    out == "true"
  end
end
