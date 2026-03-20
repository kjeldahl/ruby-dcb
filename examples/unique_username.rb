#!/usr/bin/env ruby
# frozen_string_literal: true

# Unique Username example from https://dcb.events/examples/unique-username/
#
# Demonstrates enforcing globally unique usernames via DCB:
#   - AccountRegistered claims a username
#   - AccountClosed releases it (with optional 3-day retention)
#   - UsernameChanged transfers claim between old and new
#   - Tags on username enable cross-account consistency boundaries
#
# Usage: ruby examples/unique_username.rb

require_relative "../lib/dcb_event_store"
require "pg"

module UniqueUsername
  RETENTION_DAYS = 3

  # -- Projections -----------------------------------------------------------

  def self.username_claimed(username)
    DcbEventStore::Projection.new(
      initial_state: false,
      handlers: {
        "AccountRegistered" => ->(_state, _event) { true },
        "AccountClosed"     => ->(_state, event) {
          days_ago = event.data[:days_ago]
          days_ago ? days_ago <= RETENTION_DAYS : false
        },
        "UsernameChanged"   => ->(_state, event) {
          if event.data[:new_username] == username
            true
          else
            days_ago = event.data[:days_ago]
            days_ago ? days_ago <= RETENTION_DAYS : false
          end
        }
      },
      query: DcbEventStore::Query.new([
        DcbEventStore::QueryItem.new(
          event_types: %w[AccountRegistered AccountClosed UsernameChanged],
          tags: ["username:#{username}"]
        )
      ])
    )
  end

  # -- Command Handlers ------------------------------------------------------

  def self.register_account(client, username:)
    result = DcbEventStore::DecisionModel.build(client,
      claimed: username_claimed(username)
    )

    raise "Username \"#{username}\" is claimed" if result.states[:claimed]

    client.append(
      DcbEventStore::Event.new(
        type: "AccountRegistered",
        data: { username: username },
        tags: ["username:#{username}"]
      ),
      result.append_condition
    )
  end

  def self.close_account(client, username:, days_ago: nil)
    result = DcbEventStore::DecisionModel.build(client,
      claimed: username_claimed(username)
    )

    raise "Username \"#{username}\" is not claimed" unless result.states[:claimed]

    client.append(
      DcbEventStore::Event.new(
        type: "AccountClosed",
        data: { username: username, days_ago: days_ago }.compact,
        tags: ["username:#{username}"]
      ),
      result.append_condition
    )
  end

  def self.change_username(client, old_username:, new_username:, days_ago: nil)
    result = DcbEventStore::DecisionModel.build(client,
      old_claimed: username_claimed(old_username),
      new_claimed: username_claimed(new_username)
    )

    raise "Username \"#{old_username}\" is not claimed"  unless result.states[:old_claimed]
    raise "Username \"#{new_username}\" is already claimed" if result.states[:new_claimed]

    client.append(
      DcbEventStore::Event.new(
        type: "UsernameChanged",
        data: { old_username: old_username, new_username: new_username, days_ago: days_ago }.compact,
        tags: ["username:#{old_username}", "username:#{new_username}"]
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

    puts "=== Unique Username (DCB Example) ==="
    puts

    # -- Feature 1: basic uniqueness --
    puts "--- Feature 1: Register ---"
    register_account(client, username: "alice")
    puts "[ok] Registered alice"

    register_account(client, username: "bob")
    puts "[ok] Registered bob"

    begin
      register_account(client, username: "alice")
    rescue => e
      puts "[rejected] #{e.message}"
    end

    puts

    # -- Feature 2: close releases username --
    puts "--- Feature 2: Close & reclaim ---"
    close_account(client, username: "bob")
    puts "[ok] Closed bob's account"

    register_account(client, username: "bob")
    puts "[ok] Re-registered bob (username released)"

    puts

    # -- Feature 3: username changes --
    puts "--- Feature 3: Username change ---"
    change_username(client, old_username: "alice", new_username: "alicia")
    puts "[ok] alice -> alicia"

    register_account(client, username: "alice")
    puts "[ok] Registered alice (old name freed)"

    begin
      register_account(client, username: "alicia")
    rescue => e
      puts "[rejected] #{e.message}"
    end

    puts

    # -- Feature 4: retention period --
    puts "--- Feature 4: Retention period (#{RETENTION_DAYS} days) ---"
    close_account(client, username: "alice", days_ago: 1)
    puts "[ok] Closed alice (1 day ago)"

    begin
      register_account(client, username: "alice")
    rescue => e
      puts "[rejected] #{e.message} (within retention)"
    end

    close_account(client, username: "bob", days_ago: 5)
    puts "[ok] Closed bob (5 days ago)"

    register_account(client, username: "bob")
    puts "[ok] Re-registered bob (past retention)"

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

UniqueUsername.run if __FILE__ == $0
