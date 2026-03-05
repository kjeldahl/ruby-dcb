module DcbEventStore
  SequencedEvent = Data.define(
    :sequence_position, :type, :data, :tags, :created_at,
    :id, :causation_id, :correlation_id, :schema_version
  )
end
