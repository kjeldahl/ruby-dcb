module DcbEventStore
  # The PostgreSQL store was called Store before the SQL backends were split
  # into the SqlStore template and its concrete subclasses. The old name stays
  # as an alias so existing code keeps working.
  #
  # The nested constants resolve too: Store::LockKeys through PostgresStore,
  # Store::SqlBuilder and Store::RowMapper through its SqlStore ancestor.
  Store = PostgresStore
end
