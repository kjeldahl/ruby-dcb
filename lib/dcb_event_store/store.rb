require "json"
require "time"

module DcbEventStore
  class Store
    BATCH_SIZE = 1000
    APPEND_LOCK_KEY = 0

    def initialize(conn, upcaster: nil)
      @conn = conn
      @upcaster = upcaster
    end

    def read(query)
      sql, params = build_read_sql(query)

      Enumerator.new do |yielder|
        offset = 0
        loop do
          paginated = "#{sql} LIMIT #{BATCH_SIZE} OFFSET #{offset}"
          result = @conn.exec_params(paginated, params)
          break if result.ntuples.zero?

          result.each { |row| yielder << row_to_sequenced_event(row) }
          break if result.ntuples < BATCH_SIZE

          offset += BATCH_SIZE
        end
      end
    end

    def read_from(query, after:)
      sql, params = build_read_sql(query, after: after)

      Enumerator.new do |yielder|
        offset = 0
        loop do
          paginated = "#{sql} LIMIT #{BATCH_SIZE} OFFSET #{offset}"
          result = @conn.exec_params(paginated, params)
          break if result.ntuples.zero?

          result.each { |row| yielder << row_to_sequenced_event(row) }
          break if result.ntuples < BATCH_SIZE

          offset += BATCH_SIZE
        end
      end
    end

    def append(events, condition = nil)
      events = Array(events)
      with_transaction do
        @conn.exec("SELECT pg_advisory_xact_lock($1)", [APPEND_LOCK_KEY])

        check_condition!(condition) if condition

        sequenced = events.filter_map do |event|
          result = @conn.exec_params(
            <<~SQL,
              INSERT INTO events (event_id, type, data, tags, causation_id, correlation_id, schema_version)
              VALUES ($1, $2, $3::jsonb, $4::text[], $5, $6, $7)
              ON CONFLICT (event_id) DO NOTHING
              RETURNING sequence_position, created_at
            SQL
            [event.id, event.type, JSON.generate(event.data), "{#{event.tags.join(',')}}",
             event.causation_id, event.correlation_id, 1]
          )
          next nil if result.ntuples.zero?

          row = result[0]
          SequencedEvent.new(
            sequence_position: row["sequence_position"].to_i,
            type: event.type,
            data: event.data,
            tags: event.tags,
            created_at: Time.parse(row["created_at"]),
            id: event.id,
            causation_id: event.causation_id,
            correlation_id: event.correlation_id,
            schema_version: 1
          )
        end

        notify_position = sequenced.last&.sequence_position
        @conn.exec("NOTIFY events_appended, '#{notify_position}'") if notify_position

        sequenced
      end
    end

    def subscribe(query, after: nil, &block)
      last_pos = after

      catch_up = after ? read_from(query, after: after) : read(query)
      catch_up.each do |event|
        last_pos = event.sequence_position
        block.call(event)
      end

      @conn.exec("LISTEN events_appended")
      loop do
        @conn.wait_for_notify do |_channel, _pid, _payload|
          new_events = read_from(query, after: last_pos || 0)
          new_events.each do |event|
            last_pos = event.sequence_position
            block.call(event)
          end
        end
      end
    ensure
      begin
        @conn.exec("UNLISTEN events_appended")
      rescue StandardError
        nil
      end
    end

    private

    def build_read_sql(query, after: nil)
      if query.match_all?
        return ["SELECT * FROM events WHERE sequence_position > $1 ORDER BY sequence_position ASC", [after]] if after

        return ["SELECT * FROM events ORDER BY sequence_position ASC", []]

      end

      clauses = []
      params = []

      query.items.each do |item|
        parts = []

        unless item.event_types.empty?
          params << to_pg_array(item.event_types)
          parts << "type = ANY($#{params.size}::text[])"
        end

        unless item.tags.empty?
          params << to_pg_array(item.tags)
          parts << "tags @> $#{params.size}::text[]"
        end

        clauses << "(#{parts.join(' AND ')})" unless parts.empty?
      end

      where = clauses.join(" OR ")

      if after
        params << after
        where = "(#{where}) AND sequence_position > $#{params.size}"
      end

      sql = "SELECT * FROM events WHERE #{where} ORDER BY sequence_position ASC"
      [sql, params]
    end

    def row_to_sequenced_event(row)
      type = row["type"]
      data = JSON.parse(row["data"], symbolize_names: true)
      version = row["schema_version"].to_i

      data, version = @upcaster.upcast(type, data, version) if @upcaster

      SequencedEvent.new(
        sequence_position: row["sequence_position"].to_i,
        type: type,
        data: data,
        tags: parse_pg_array(row["tags"]),
        created_at: Time.parse(row["created_at"]),
        id: row["event_id"],
        causation_id: row["causation_id"],
        correlation_id: row["correlation_id"],
        schema_version: version
      )
    end

    def parse_pg_array(str)
      return [] if str.nil? || str == "{}"

      str.delete_prefix("{").delete_suffix("}").split(",").map { |s| s.delete('"') }
    end

    def to_pg_array(arr)
      "{#{arr.join(',')}}"
    end

    def check_condition!(condition)
      query = condition.fail_if_events_match
      sql, params = build_condition_sql(query, condition.after)
      result = @conn.exec_params(sql, params)
      count = result[0]["count"].to_i
      raise ConditionNotMet, "#{count} conflicting event(s)" if count.positive?
    end

    def build_condition_sql(query, after)
      if query.match_all?
        return ["SELECT COUNT(*) FROM events WHERE sequence_position > $1", [after]] if after

        return ["SELECT COUNT(*) FROM events", []]

      end

      clauses = []
      params = []

      query.items.each do |item|
        parts = []

        unless item.event_types.empty?
          params << to_pg_array(item.event_types)
          parts << "type = ANY($#{params.size}::text[])"
        end

        unless item.tags.empty?
          params << to_pg_array(item.tags)
          parts << "tags @> $#{params.size}::text[]"
        end

        clauses << "(#{parts.join(' AND ')})" unless parts.empty?
      end

      where = clauses.join(" OR ")

      if after
        params << after
        where = "(#{where}) AND sequence_position > $#{params.size}"
      end

      ["SELECT COUNT(*) FROM events WHERE #{where}", params]
    end

    def with_transaction
      @conn.exec("BEGIN")
      result = yield
      @conn.exec("COMMIT")
      result
    rescue StandardError
      begin
        @conn.exec("ROLLBACK")
      rescue StandardError
        nil
      end
      raise
    end
  end
end
