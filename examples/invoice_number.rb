#!/usr/bin/env ruby
# frozen_string_literal: true

# Invoice Number example from https://dcb.events/examples/invoice-number/
#
# Demonstrates monotonic, gap-free invoice numbering via DCB.
# The projection tracks the next number; the append condition
# prevents concurrent duplicate assignment.
#
# Usage: ruby examples/invoice_number.rb

require_relative "../lib/dcb_event_store"
require "pg"

module InvoiceNumber
  # -- Projections -----------------------------------------------------------

  def self.next_invoice_number
    DcbEventStore::Projection.new(
      initial_state: 1,
      handlers: {
        "InvoiceCreated" => ->(_state, event) { event.data[:invoice_number] + 1 }
      },
      query: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(event_types: ["InvoiceCreated"])
      ])
    )
  end

  # -- Command Handlers ------------------------------------------------------

  def self.create_invoice(client, invoice_data:)
    result = DcbEventStore::DecisionModel.build(client,
      next_number: next_invoice_number
    )

    number = result.states[:next_number]

    client.append(
      DcbEventStore::Event.new(
        type: "InvoiceCreated",
        data: { invoice_number: number, invoice_data: invoice_data },
        tags: ["invoice:#{number}"]
      ),
      result.append_condition
    )

    number
  end

  # -- Demo ------------------------------------------------------------------

  def self.run
    conn = PG.connect(dbname: "dcb_event_store_test")
    conn.exec("SET client_min_messages TO warning")
    DcbEventStore::Schema.create!(conn)
    conn.exec("TRUNCATE events RESTART IDENTITY")
    store = DcbEventStore::Store.new(conn)
    client = DcbEventStore::Client.new(store)

    puts "=== Invoice Number (DCB Example) ==="
    puts

    5.times do |i|
      num = create_invoice(client, invoice_data: { description: "Service #{i + 1}" })
      puts "[ok] Created invoice ##{num}"
    end

    # Concurrent attempt -- simulate conflict
    puts
    puts "--- Concurrent conflict ---"
    result1 = DcbEventStore::DecisionModel.build(client, next_number: next_invoice_number)
    result2 = DcbEventStore::DecisionModel.build(client, next_number: next_invoice_number)

    # First wins
    client.append(
      DcbEventStore::Event.new(
        type: "InvoiceCreated",
        data: { invoice_number: result1.states[:next_number], invoice_data: { description: "Winner" } },
        tags: ["invoice:#{result1.states[:next_number]}"]
      ),
      result1.append_condition
    )
    puts "[ok] First append: invoice ##{result1.states[:next_number]}"

    # Second fails
    begin
      client.append(
        DcbEventStore::Event.new(
          type: "InvoiceCreated",
          data: { invoice_number: result2.states[:next_number], invoice_data: { description: "Loser" } },
          tags: ["invoice:#{result2.states[:next_number]}"]
        ),
        result2.append_condition
      )
    rescue DcbEventStore::ConditionNotMet => e
      puts "[rejected] Second append: #{e.message} (would have duplicated ##{result2.states[:next_number]})"
    end

    puts
    puts "=== Event Log ==="
    client.read(DcbEventStore::Query.all).each do |e|
      puts "  ##{e.sequence_position} #{e.type} data=#{e.data.inspect}"
    end

    puts
    puts "Done. #{client.read(DcbEventStore::Query.all).count} invoices total."
  ensure
    conn&.close
  end
end

InvoiceNumber.run if __FILE__ == $0
