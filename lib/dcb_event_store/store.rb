require "json"

module DcbEventStore
  class Store
    BATCH_SIZE = 1000
    APPEND_LOCK_KEY = 0

    def initialize(conn)
      @conn = conn
    end

    def read(query)
      sql, params = build_read_sql(query)

      Enumerator.new do |yielder|
        offset = 0
        loop do
          paginated = "#{sql} LIMIT #{BATCH_SIZE} OFFSET #{offset}"
          result = @conn.exec_params(paginated, params)
          break if result.ntuples == 0

          result.each { |row| yielder << row_to_sequenced_event(row) }
          break if result.ntuples < BATCH_SIZE
          offset += BATCH_SIZE
        end
      end
    end

    private

    def build_read_sql(query)
      if query.match_all?
        return ["SELECT * FROM events ORDER BY sequence_position ASC", []]
      end

      clauses = []
      params = []

      query.items.each do |item|
        parts = []

        unless item.event_types.empty?
          params << item.event_types
          parts << "type = ANY($#{params.size})"
        end

        unless item.tags.empty?
          params << item.tags
          parts << "tags @> $#{params.size}::text[]"
        end

        clauses << "(#{parts.join(" AND ")})" unless parts.empty?
      end

      sql = "SELECT * FROM events WHERE #{clauses.join(" OR ")} ORDER BY sequence_position ASC"
      [sql, params]
    end

    def row_to_sequenced_event(row)
      SequencedEvent.new(
        sequence_position: row["sequence_position"].to_i,
        type: row["type"],
        data: JSON.parse(row["data"], symbolize_names: true),
        tags: parse_pg_array(row["tags"]),
        created_at: Time.parse(row["created_at"])
      )
    end

    def parse_pg_array(str)
      return [] if str.nil? || str == "{}"
      str.delete_prefix("{").delete_suffix("}").split(",").map { |s| s.delete('"') }
    end
  end
end
