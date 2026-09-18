#!/usr/bin/env ruby
# frozen_string_literal: true

# Prevent Record Duplication example from https://dcb.events/examples/prevent-record-duplication/
#
# Demonstrates idempotency tokens via DCB. Each order carries a
# client-generated token; the decision model rejects re-submissions.
#
# Usage: ruby examples/prevent_record_duplication.rb
#        DCB_BACKEND=sqlite ruby examples/prevent_record_duplication.rb   # or postgres (default), memory

require_relative "../lib/dcb_event_store"
require_relative "support/backend"
require "securerandom"

module PreventRecordDuplication
  # -- Projections -----------------------------------------------------------

  def self.idempotency_token_used(token)
    DcbEventStore::Projection.new(
      initial_state: false,
      handlers: {
        "OrderPlaced" => ->(_state, _event) { true }
      },
      query: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(
          event_types: ["OrderPlaced"],
          tags: ["idempotency:#{token}"]
        )
      ])
    )
  end

  # -- Command Handlers ------------------------------------------------------

  def self.place_order(client, order_id:, idempotency_token:)
    result = DcbEventStore::DecisionModel.build(client,
      token_used: idempotency_token_used(idempotency_token)
    )

    raise "Re-submission (token #{idempotency_token} already used)" if result.states[:token_used]

    client.append(
      DcbEventStore::Event.new(
        type: "OrderPlaced",
        data: { order_id: order_id, idempotency_token: idempotency_token },
        tags: ["order:#{order_id}", "idempotency:#{idempotency_token}"]
      ),
      result.append_condition
    )
  end

  # -- Demo ------------------------------------------------------------------

  def self.run
    Examples::Backend.with_store { |store| demo(DcbEventStore::Client.new(store)) }
  end

  # The example itself, on whichever backend DCB_BACKEND selected.
  def self.demo(client)
    puts "=== Prevent Record Duplication (DCB Example) ==="
    puts

    # Place orders with unique tokens
    token1 = SecureRandom.uuid
    place_order(client, order_id: "order-1", idempotency_token: token1)
    puts "[ok] Placed order-1 (token: #{token1[0..7]}...)"

    token2 = SecureRandom.uuid
    place_order(client, order_id: "order-2", idempotency_token: token2)
    puts "[ok] Placed order-2 (token: #{token2[0..7]}...)"

    puts

    # Re-submit with same token -- rejected
    puts "--- Re-submission ---"
    begin
      place_order(client, order_id: "order-1-retry", idempotency_token: token1)
    rescue => e
      puts "[rejected] #{e.message}"
    end

    # Different token, same order_id -- allowed (different idempotency boundary)
    token3 = SecureRandom.uuid
    place_order(client, order_id: "order-1", idempotency_token: token3)
    puts "[ok] Placed order-1 again with new token (#{token3[0..7]}...)"

    puts
    puts "=== Event Log ==="
    client.read(DcbEventStore::Query.all).each do |e|
      puts "  ##{e.sequence_position} #{e.type} tags=#{e.tags.inspect} data=#{e.data.inspect}"
    end

    puts
    puts "Done. #{client.read(DcbEventStore::Query.all).count} events total."
  end
end

PreventRecordDuplication.run if __FILE__ == $0
