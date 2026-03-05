module DcbEventStore
  SequencedEvent = Data.define(:sequence_position, :type, :data, :tags, :created_at, :id)
end
