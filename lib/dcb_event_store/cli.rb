require "optparse"
require_relative "../dcb_event_store"

module DcbEventStore
  # Command line front end to EventFile, run by bin/dcb_events:
  #
  #   dcb_events export -b sqlite -d events.sqlite3 > events.jsonl
  #   dcb_events import -b postgres -d my_event_store --create-schema seeds.jsonl
  #
  # Not loaded with the gem: only the executable requires it.
  class CLI
    BACKENDS = %w[postgres sqlite].freeze
    USAGE = <<~TEXT.freeze
      Usage: dcb_events export|import [options] [FILE]

      Exports events to, or imports them from, JSON Lines (one event per line).
      FILE defaults to stdout (export) / stdin (import); "-" means the same.
    TEXT

    def self.run(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr)
      new(stdin: stdin, stdout: stdout, stderr: stderr).run(argv)
    end

    def initialize(stdin:, stdout:, stderr:)
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
    end

    # Returns the process exit status.
    def run(argv)
      options = parse(argv.dup)
      return 0 if options.nil?

      with_store(options) do |store|
        options[:command] == "export" ? export(store, options) : import(store, options)
      end
      0
    rescue OptionParser::ParseError, ArgumentError => e
      @stderr.puts("dcb_events: #{e.message}")
      64
    rescue StandardError => e
      @stderr.puts("dcb_events: #{e.class}: #{e.message}")
      1
    end

    private

    def parse(argv)
      options = {
        backend: ENV.fetch("DCB_BACKEND", nil),
        database: ENV.fetch("DATABASE_URL", nil),
        types: [],
        tags: [],
        batch_size: EventFile::DEFAULT_BATCH_SIZE
      }
      parser = option_parser(options)
      parser.parse!(argv)
      return help(parser) if options[:help]

      options[:command] = argv.shift
      options[:file] = argv.shift
      validate!(options, argv)
      options
    end

    def option_parser(options)
      OptionParser.new do |o|
        o.banner = USAGE
        o.separator ""
        o.on("-b", "--backend NAME", BACKENDS, "postgres or sqlite (default: $DCB_BACKEND)") do |v|
          options[:backend] = v
        end
        o.on("-d", "--database DB",
             "PostgreSQL dbname, conninfo or URL; SQLite file path (default: $DATABASE_URL)") do |v|
          options[:database] = v
        end
        o.separator ""
        o.separator "export:"
        o.on("--type TYPE", "Only events of this type (repeatable: any of)") { |v| options[:types] << v }
        o.on("--tag TAG", "Only events carrying this tag (repeatable: all of)") { |v| options[:tags] << v }
        o.on("--after POSITION", Integer, "Only events after this sequence position") { |v| options[:after] = v }
        o.on("--description TEXT", "Free text for the file's header line") { |v| options[:description] = v }
        o.separator ""
        o.separator "import:"
        o.on("--create-schema", "Install the schema first (idempotent)") { options[:create_schema] = true }
        o.on("--batch-size N", Integer, "Events per transaction, 0 = whole file in one (default: 1000)") do |v|
          raise OptionParser::InvalidArgument, "must be >= 0" if v.negative?

          options[:batch_size] = v.zero? ? nil : v
        end
        o.on("-h", "--help", "Show this help") { options[:help] = true }
      end
    end

    def help(parser)
      @stdout.puts(parser)
      nil
    end

    def validate!(options, rest)
      unless %w[export import].include?(options[:command])
        raise ArgumentError, "expected command export or import, got #{options[:command].inspect}"
      end
      raise ArgumentError, "unexpected argument(s): #{rest.join(' ')}" unless rest.empty?
      raise ArgumentError, "--backend is required (postgres or sqlite)" if options[:backend].nil?
      unless BACKENDS.include?(options[:backend])
        raise ArgumentError, "unknown backend #{options[:backend].inspect} (expected postgres or sqlite)"
      end
      raise ArgumentError, "--database is required" if options[:database].nil?
    end

    def export(store, options)
      query = if options[:types].empty? && options[:tags].empty?
                Query.all
              else
                Query.new([QueryItem.new(event_types: options[:types], tags: options[:tags])])
              end
      count = with_file(options[:file], "w", @stdout) do |io|
        EventFile.export(store, io, query: query, after: options[:after], description: options[:description])
      end
      @stderr.puts("exported #{count} event(s)")
    end

    def import(store, options)
      result = with_file(options[:file], "r", @stdin) do |io|
        EventFile.import(store, io, batch_size: options[:batch_size])
      end
      @stderr.puts("imported #{result.imported} event(s), skipped #{result.skipped} already stored")
      @stderr.puts(describe(result.header)) if result.header
    end

    # One line naming where an imported file came from.
    def describe(header)
      parts = ["exported #{header.exported_at&.iso8601 || 'at an unknown time'}"]
      parts << "from #{header.store}" if header.store
      parts << "by dcb_event_store #{header.gem_version}" if header.gem_version
      parts << "query #{header.query}" unless header.query.match_all?
      parts << "after #{header.after}" if header.after
      parts << "(#{header.description})" if header.description
      "file: #{parts.join(' ')}"
    end

    def with_file(path, mode, default, &)
      return yield(default) if path.nil? || path == "-"

      File.open(path, mode, &)
    end

    def with_store(options, &)
      options[:backend] == "postgres" ? with_postgres(options, &) : with_sqlite(options, &)
    end

    # A bare name is a dbname; anything with "=" or "://" is handed to libpq
    # as a conninfo string or URL.
    def with_postgres(options)
      require "pg"
      db = options[:database]
      conn = db.match?(%r{=|://}) ? PG.connect(db) : PG.connect(dbname: db)
      conn.exec("SET client_min_messages TO warning")
      PostgresStore::Schema.create!(conn) if options[:create_schema]
      yield PostgresStore.new(conn)
    ensure
      conn&.close
    end

    # Export never creates a database: SQLite would open a missing path as
    # a new, empty file.
    def with_sqlite(options)
      require "sqlite3"
      path = options[:database]
      if options[:command] == "export" && path != ":memory:" && !File.exist?(path)
        raise ArgumentError, "no SQLite database at #{path}"
      end

      db = SQLite3::Database.new(path)
      options[:create_schema] ? SqliteStore::Schema.create!(db) : SqliteStore::Schema.configure!(db)
      yield SqliteStore.new(db)
    ensure
      db&.close
    end
  end
end
