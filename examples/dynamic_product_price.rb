#!/usr/bin/env ruby
# frozen_string_literal: true

# Dynamic Product Price example from https://dcb.events/examples/dynamic-product-price/
#
# Demonstrates price validation with a grace period. Orders must use a
# currently valid price. After a price change, old prices remain valid
# for a configurable grace period (simulated via minutes_ago metadata).
#
# Usage: ruby examples/dynamic_product_price.rb

require_relative "../lib/dcb_event_store"
require "pg"

module DynamicProductPrice
  GRACE_PERIOD_MINUTES = 10

  # -- Projections -----------------------------------------------------------

  def self.product_price(product_id)
    DcbEventStore::Projection.new(
      initial_state: { last_valid_old_price: nil, valid_new_prices: [] },
      handlers: {
        "ProductDefined" => ->(_state, event) {
          if (event.data[:minutes_ago] || Float::INFINITY) <= GRACE_PERIOD_MINUTES
            { last_valid_old_price: nil, valid_new_prices: [event.data[:price]] }
          else
            { last_valid_old_price: event.data[:price], valid_new_prices: [] }
          end
        },
        "ProductPriceChanged" => ->(state, event) {
          if (event.data[:minutes_ago] || Float::INFINITY) <= GRACE_PERIOD_MINUTES
            { last_valid_old_price: state[:last_valid_old_price],
              valid_new_prices: state[:valid_new_prices] + [event.data[:new_price]] }
          else
            { last_valid_old_price: event.data[:new_price],
              valid_new_prices: state[:valid_new_prices] }
          end
        }
      },
      query: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(
          event_types: %w[ProductDefined ProductPriceChanged],
          tags: ["product:#{product_id}"]
        )
      ])
    )
  end

  def self.product_exists(product_id)
    DcbEventStore::Projection.new(
      initial_state: false,
      handlers: { "ProductDefined" => ->(_state, _event) { true } },
      query: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(event_types: ["ProductDefined"], tags: ["product:#{product_id}"])
      ])
    )
  end

  # -- Command Handlers ------------------------------------------------------

  def self.define_product(client, product_id:, price:)
    result = DcbEventStore::DecisionModel.build(client,
      exists: product_exists(product_id)
    )
    raise "Product #{product_id} already exists" if result.states[:exists]

    client.append(
      DcbEventStore::Event.new(
        type: "ProductDefined",
        data: { product_id: product_id, price: price },
        tags: ["product:#{product_id}"]
      ),
      result.append_condition
    )
  end

  def self.change_price(client, product_id:, new_price:, minutes_ago: nil)
    result = DcbEventStore::DecisionModel.build(client,
      exists: product_exists(product_id)
    )
    raise "Product #{product_id} does not exist" unless result.states[:exists]

    client.append(
      DcbEventStore::Event.new(
        type: "ProductPriceChanged",
        data: { product_id: product_id, new_price: new_price, minutes_ago: minutes_ago }.compact,
        tags: ["product:#{product_id}"]
      ),
      result.append_condition
    )
  end

  def self.order_products(client, items:)
    projections = items.each_with_object({}) do |item, h|
      h[item[:product_id].to_sym] = product_price(item[:product_id])
    end

    result = DcbEventStore::DecisionModel.build(client, **projections)

    items.each do |item|
      state = result.states[item[:product_id].to_sym]
      displayed = item[:displayed_price]

      valid = state[:last_valid_old_price] == displayed ||
              state[:valid_new_prices].include?(displayed)

      raise "Invalid price #{displayed} for product \"#{item[:product_id]}\"" unless valid
    end

    tags = items.map { |i| "product:#{i[:product_id]}" }
    client.append(
      DcbEventStore::Event.new(
        type: "ProductsOrdered",
        data: { items: items.map { |i| { product_id: i[:product_id], price: i[:displayed_price] } } },
        tags: tags
      ),
      result.append_condition
    )
  end

  # -- Demo ------------------------------------------------------------------

  def self.run
    conn = PG.connect(dbname: "dcb_event_store_test")
    conn.exec("SET client_min_messages TO warning")
    DcbEventStore::Schema.create!(conn)
    conn.exec("TRUNCATE events RESTART IDENTITY")
    store = DcbEventStore::Store.new(conn)
    client = DcbEventStore::Client.new(store)

    puts "=== Dynamic Product Price (DCB Example) ==="
    puts

    define_product(client, product_id: "widget", price: 1000)
    puts "[ok] Defined widget @ $10.00"

    define_product(client, product_id: "gadget", price: 2500)
    puts "[ok] Defined gadget @ $25.00"

    # Order at current price
    order_products(client, items: [
      { product_id: "widget", displayed_price: 1000 },
      { product_id: "gadget", displayed_price: 2500 }
    ])
    puts "[ok] Ordered widget + gadget at current prices"

    puts

    # Price change within grace period -- old price still valid
    puts "--- Price change (within grace period) ---"
    change_price(client, product_id: "widget", new_price: 1200, minutes_ago: 5)
    puts "[ok] Widget price changed to $12.00 (5 min ago)"

    order_products(client, items: [
      { product_id: "widget", displayed_price: 1000 }
    ])
    puts "[ok] Ordered widget at old price $10.00 (still valid, within grace)"

    order_products(client, items: [
      { product_id: "widget", displayed_price: 1200 }
    ])
    puts "[ok] Ordered widget at new price $12.00"

    puts

    # Price change outside grace period -- old price invalid
    puts "--- Price change (past grace period) ---"
    change_price(client, product_id: "gadget", new_price: 3000, minutes_ago: 30)
    puts "[ok] Gadget price changed to $30.00 (30 min ago)"

    begin
      order_products(client, items: [
        { product_id: "gadget", displayed_price: 2500 }
      ])
    rescue => e
      puts "[rejected] #{e.message}"
    end

    order_products(client, items: [
      { product_id: "gadget", displayed_price: 3000 }
    ])
    puts "[ok] Ordered gadget at current price $30.00"

    puts
    puts "=== Event Log ==="
    client.read(DcbEventStore::Query.all).each do |e|
      puts "  ##{e.sequence_position} #{e.type} tags=#{e.tags.inspect} data=#{e.data.inspect}"
    end

    puts
    puts "Done. #{client.read(DcbEventStore::Query.all).count} events total."
  ensure
    conn&.close
  end
end

DynamicProductPrice.run if __FILE__ == $0
