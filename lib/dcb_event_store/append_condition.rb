module DcbEventStore
  AppendCondition = Data.define(:fail_if_events_match, :after) do
    def initialize(fail_if_events_match:, after: nil)
      super
    end
  end
end
