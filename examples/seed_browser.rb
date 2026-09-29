# Seeds the test database with a realistic, varied event stream so the web
# browser (examples/config.ru) has something interesting to show.
#
#   bundle exec ruby examples/seed_browser.rb
#
# Resets the events table, then appends a few customer/order/course sagas -
# each saga's events share a correlation_id (stamped by Client) so causation
# and correlation are populated. Also builds a few projection snapshots and
# fills two extra namespaces ("billing", "shipping") so the browser's
# namespace switcher and snapshot pages have something to show.

require_relative "../lib/dcb_event_store"
require "pg"
require "dcb_event_store/web"

DB = ENV.fetch("DCB_DB", "dcb_event_store_test")

conn = PG.connect(dbname: DB)
conn.exec("SET client_min_messages TO warning")
DcbEventStore::PostgresStore::Schema.create!(conn)
conn.exec("TRUNCATE events RESTART IDENTITY")
conn.exec("TRUNCATE projection_snapshots")

store = DcbEventStore::PostgresStore.new(conn)

def ev(type, data, *tags)
  DcbEventStore::Event.new(type: type, data: data, tags: tags)
end

total = 0

# --- Customer + order sagas ------------------------------------------------
customers = [
  { id: 1, name: "Ada Lovelace",   email: "ada@example.com" },
  { id: 2, name: "Alan Turing",    email: "alan@example.com" },
  { id: 3, name: "Grace Hopper",   email: "grace@example.com" },
  { id: 4, name: "Edsger Dijkstra", email: "edsger@example.com" }
]

products = [
  { sku: "BOOK-042", name: "The Annotated Turing", price: 39.0 },
  { sku: "MUG-007",  name: "Enigma Mug",           price: 14.5 },
  { sku: "TEE-128",  name: "Nand2Tetris Tee",      price: 24.0 }
]

order_no = 1000
customers.each do |c|
  # One client per customer-registration saga: correlation flows through.
  reg_client = DcbEventStore::Client.new(store)
  reg_client.append([
    ev("CustomerRegistered", { customer_id: c[:id], name: c[:name], email: c[:email] }, "customer:#{c[:id]}")
  ])
  total += 1

  # Each customer places 1-2 orders; each order is its own saga.
  n_orders = (c[:id].even? ? 2 : 1)
  n_orders.times do |i|
    order_no += 1
    order_tag = "order:#{order_no}"
    cust_tag = "customer:#{c[:id]}"
    picked = products.rotate(c[:id] + i).first(1 + (i % 2))
    lines = picked.map { |p| { sku: p[:sku], name: p[:name], qty: 1, price: p[:price] } }
    amount = lines.sum { |l| l[:price] }

    order_client = DcbEventStore::Client.new(store)
    e1 = order_client.append([
      ev("OrderPlaced",
         { order_no: order_no, customer_id: c[:id], lines: lines, amount: amount, currency: "EUR" },
         order_tag, cust_tag)
    ]).first
    total += 1

    # Payment (caused_by the OrderPlaced event → causation chain).
    pay_client = order_client.caused_by(e1)
    pay = pay_client.append([
      ev("PaymentAuthorized",
         { order_no: order_no, amount: amount, method: (order_no.even? ? "card" : "invoice") },
         order_tag, cust_tag)
    ]).first
    total += 1

    if order_no.even?
      ship = pay_client.caused_by(pay).append([
        ev("OrderShipped",
           { order_no: order_no, carrier: %w[UPS DHL PostNord][order_no % 3], tracking: "TRK#{order_no}X" },
           order_tag, cust_tag)
      ]).first
      total += 1
      pay_client.caused_by(ship).append([
        ev("OrderDelivered", { order_no: order_no, signed_by: c[:name] }, order_tag, cust_tag)
      ])
      total += 1
    else
      order_client.append([
        ev("OrderCancelled", { order_no: order_no, reason: "customer request" }, order_tag, cust_tag)
      ])
      total += 1
    end
  end
end

# --- Course subscription events (different bounded context) -----------------
courses = [
  { id: "dcb-101", title: "DCB Fundamentals", seats: 30 },
  { id: "es-201",  title: "Event Sourcing in Depth", seats: 20 }
]
courses.each do |course|
  store.append([ev("CourseDefined", { course_id: course[:id], title: course[:title], seats: course[:seats] },
                   "course:#{course[:id]}")])
  total += 1
  customers.first(3).each do |c|
    store.append([ev("StudentSubscribed", { course_id: course[:id], customer_id: c[:id] },
                     "course:#{course[:id]}", "customer:#{c[:id]}")])
    total += 1
  end
end

# --- A burst of low-signal events to exercise pagination --------------------
40.times do |i|
  store.append([ev("CartItemAdded", { session: "s-#{i}", sku: products[i % products.size][:sku] }, "session:s-#{i}")])
  total += 1
end

# --- Snapshots: what DecisionModel.build leaves behind -----------------------
snapshots = DcbEventStore::Snapshots::PostgresSnapshotStore.new(conn)
%w[dcb-101 es-201].each do |course_id|
  subscriptions = DcbEventStore::Projection.new(
    initial_state: 0,
    handlers: { "StudentSubscribed" => ->(count, _e) { count + 1 } },
    query: DcbEventStore::Query.new([
      DcbEventStore::QueryItem.new(event_types: %w[StudentSubscribed], tags: ["course:#{course_id}"])
    ]),
    snapshot: DcbEventStore::Snapshot.new(name: "course_subscriptions", version: 1)
  )
  DcbEventStore::DecisionModel.build(store, snapshots: snapshots, subscriptions: subscriptions)
end
customers.each do |c|
  spent = DcbEventStore::Projection.new(
    initial_state: { orders: 0, total: 0.0 },
    handlers: { "OrderPlaced" => ->(s, e) { { orders: s[:orders] + 1, total: s[:total] + e.data[:amount] } } },
    query: DcbEventStore::Query.new([
      DcbEventStore::QueryItem.new(event_types: %w[OrderPlaced], tags: ["customer:#{c[:id]}"])
    ]),
    snapshot: DcbEventStore::Snapshot.new(name: "customer_spend", version: 2)
  )
  DcbEventStore::DecisionModel.build(store, snapshots: snapshots, spend: spent)
end
# A new event after the snapshots were written, so one of them is behind head.
store.append([ev("StudentSubscribed", { course_id: "dcb-101", customer_id: 4 }, "course:dcb-101", "customer:4")])
total += 1

# --- Other namespaces: separate logs in the same database --------------------
%w[billing shipping].each do |name|
  DcbEventStore::PostgresStore::Schema.drop!(conn, namespace: name)
  DcbEventStore::PostgresStore::Schema.create!(conn, namespace: name)
end
billing = DcbEventStore::PostgresStore.new(PG.connect(dbname: DB), namespace: "billing")
shipping = DcbEventStore::PostgresStore.new(PG.connect(dbname: DB), namespace: "shipping")

(1..6).each do |n|
  billing.append([ev("InvoiceIssued", { invoice: "INV-#{n}", amount: 20.0 * n }, "invoice:INV-#{n}")])
  billing.append([ev("InvoicePaid", { invoice: "INV-#{n}" }, "invoice:INV-#{n}")]) if n.odd?
end
billing_snapshots = DcbEventStore::Snapshots::PostgresSnapshotStore.new(conn, namespace: "billing")
open_invoices = DcbEventStore::Projection.new(
  initial_state: [],
  handlers: { "InvoiceIssued" => ->(open, e) { open + [e.data[:invoice]] },
              "InvoicePaid" => ->(open, e) { open - [e.data[:invoice]] } },
  query: DcbEventStore::Query.new([
    DcbEventStore::QueryItem.new(event_types: %w[InvoiceIssued InvoicePaid], tags: [])
  ]),
  snapshot: DcbEventStore::Snapshot.new(name: "open_invoices", version: 1)
)
DcbEventStore::DecisionModel.build(billing, snapshots: billing_snapshots, open: open_invoices)

3.times do |n|
  shipping.append([ev("ParcelPacked", { parcel: "P-#{n}", weight_kg: 1.5 + n }, "parcel:P-#{n}"),
                   ev("ParcelDispatched", { parcel: "P-#{n}", carrier: "DHL" }, "parcel:P-#{n}")])
end

puts "Seeded #{total} events into #{DB}."
puts "Types: #{conn.exec('SELECT DISTINCT type FROM events ORDER BY type').map { |r| r['type'] }.join(', ')}"
puts "Snapshots: #{conn.exec('SELECT count(*) FROM projection_snapshots').getvalue(0, 0)} (default), " \
     "#{conn.exec('SELECT count(*) FROM billing_projection_snapshots').getvalue(0, 0)} (billing)"
puts "Namespaces: #{DcbEventStore::Web::ReadModel.namespaces(conn).map { |n| n || 'default' }.join(', ')}"
puts "Head position: #{conn.exec('SELECT max(sequence_position) FROM events').getvalue(0, 0)}"
conn.close
