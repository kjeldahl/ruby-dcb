#!/usr/bin/env ruby
# frozen_string_literal: true

# Opt-In Token example from https://dcb.events/examples/opt-in-token/
#
# Demonstrates using DCB for token-based sign-up confirmation without
# a separate token store. The OTP lives in the event stream; projections
# track pending state, usage, and expiry.
#
# Usage: ruby examples/opt_in_token.rb

require_relative "../lib/dcb_event_store"
require "pg"
require "securerandom"

module OptInToken
  OTP_EXPIRY_MINUTES = 60

  # -- Projections -----------------------------------------------------------

  def self.pending_sign_up(email, otp)
    DcbEventStore::Projection.new(
      initial_state: nil,
      handlers: {
        "SignUpInitiated" => ->(_state, event) {
          { data: event.data, otp_used: false, otp_expired: false }
        },
        "SignUpConfirmed" => ->(state, _event) {
          state&.merge(otp_used: true)
        }
      },
      query: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(
          event_types: %w[SignUpInitiated SignUpConfirmed],
          tags: ["email:#{email}", "otp:#{otp}"]
        )
      ])
    )
  end

  # -- Command Handlers ------------------------------------------------------

  def self.initiate_sign_up(client, email:, name:)
    otp = SecureRandom.hex(4)

    client.append(
      DcbEventStore::Event.new(
        type: "SignUpInitiated",
        data: { email: email, otp: otp, name: name },
        tags: ["email:#{email}", "otp:#{otp}"]
      )
    )

    otp
  end

  def self.confirm_sign_up(client, email:, otp:, minutes_ago: 0)
    result = DcbEventStore::DecisionModel.build(client,
      pending: pending_sign_up(email, otp)
    )

    state = result.states[:pending]
    raise "No pending sign-up for #{email} with this OTP"   if state.nil?
    raise "OTP already used"                                 if state[:otp_used]
    raise "OTP expired (>#{OTP_EXPIRY_MINUTES} min)"         if minutes_ago > OTP_EXPIRY_MINUTES

    client.append(
      DcbEventStore::Event.new(
        type: "SignUpConfirmed",
        data: { email: email, otp: otp, name: state[:data][:name] },
        tags: ["email:#{email}", "otp:#{otp}"]
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

    puts "=== Opt-In Token (DCB Example) ==="
    puts

    # Initiate sign-up
    otp = initiate_sign_up(client, email: "alice@example.com", name: "Alice")
    puts "[ok] Sign-up initiated for alice@example.com (OTP: #{otp})"

    # Confirm with correct OTP
    confirm_sign_up(client, email: "alice@example.com", otp: otp)
    puts "[ok] Sign-up confirmed"

    # Try to re-use OTP
    begin
      confirm_sign_up(client, email: "alice@example.com", otp: otp)
    rescue => e
      puts "[rejected] #{e.message}"
    end

    puts

    # Wrong OTP
    puts "--- Wrong OTP ---"
    otp2 = initiate_sign_up(client, email: "bob@example.com", name: "Bob")
    puts "[ok] Sign-up initiated for bob@example.com (OTP: #{otp2})"

    begin
      confirm_sign_up(client, email: "bob@example.com", otp: "wrong")
    rescue => e
      puts "[rejected] #{e.message}"
    end

    puts

    # Expired OTP
    puts "--- Expired OTP ---"
    otp3 = initiate_sign_up(client, email: "charlie@example.com", name: "Charlie")
    puts "[ok] Sign-up initiated for charlie@example.com (OTP: #{otp3})"

    begin
      confirm_sign_up(client, email: "charlie@example.com", otp: otp3, minutes_ago: 90)
    rescue => e
      puts "[rejected] #{e.message}"
    end

    # Valid confirmation for bob
    confirm_sign_up(client, email: "bob@example.com", otp: otp2)
    puts "[ok] Bob confirmed"

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

OptInToken.run if __FILE__ == $0
