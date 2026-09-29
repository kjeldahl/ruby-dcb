module DcbEventStore
  # One question a store's #settled answers: are exactly +count+ events
  # matching +query+ stored in (+after+, +through+] (+after+ nil = from the
  # start), with no append still in flight that could add one there? What
  # DecisionModel asks before it writes a snapshot at +through+.
  SettleCheck = Data.define(:query, :after, :through, :count)
end
