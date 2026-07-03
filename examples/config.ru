# Standalone Rack server for the event browser:
#
#   bundle exec rackup examples/config.ru
#   open http://localhost:9292
#
# In a Rails app instead, add to config/routes.rb:
#
#   require "dcb_event_store/web"
#   mount DcbEventStore::Web => "/dcb"
#
# and set the connection in an initializer (config/initializers/dcb.rb):
#
#   DcbEventStore::Web.connection = -> { PG.connect(dbname: "your_db") }
#   # or, in an ActiveRecord app, leave it unset to borrow AR's connection.

require "dcb_event_store/web"
require "pg"

# Memoized so a connection is opened once and reused across requests, not one
# per request. (This dev server is single-process; a real multi-threaded
# deployment would hand out a pooled/per-thread connection instead.)
CONN = PG.connect(dbname: ENV.fetch("DCB_DB", "dcb_event_store_test"))
DcbEventStore::Web.connection = -> { CONN }

run DcbEventStore::Web
