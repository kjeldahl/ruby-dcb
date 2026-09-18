module DcbEventStore
  # The PostgreSQL store was called Store before the SQL backends were split
  # into the SqlStore template and its concrete subclasses. The old name stays
  # as an alias so existing code keeps working.
  #
  # The nested constants resolve too: Store::LockKeys through PostgresStore,
  # Store::SqlBuilder and Store::RowMapper through its SqlStore ancestor.
  Store = PostgresStore

  # The schema module moved under PostgresStore along with the store itself.
  Schema = PostgresStore::Schema

  # The PG array codec likewise moved under PostgresStore when the dialects
  # were split out; the old top-level name stays as an alias.
  PgArrayCodec = PostgresStore::ArrayCodec

  # Referencing any of the three prints "constant DcbEventStore::Store is
  # deprecated". A constant cannot carry a reader hook, so the warning comes
  # from Ruby itself, which means it obeys the deprecation category: it shows
  # up under `ruby -w`, `-W:deprecated` or `Warning[:deprecated] = true` and
  # stays quiet otherwise, rather than writing a line per access in
  # applications that have not moved over yet.
  deprecate_constant :Store, :Schema, :PgArrayCodec
end
