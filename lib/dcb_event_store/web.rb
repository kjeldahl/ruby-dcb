# Optional, framework-agnostic web browser for the event store. NOT required by
# lib/dcb_event_store.rb - load it explicitly (`require "dcb_event_store/web"`)
# only where you want to mount the UI. Adds no runtime dependency to the core
# gem; the Rack app references Rack lazily at request time, so the host app
# (Rails, Sinatra, bare Rack) supplies Rack.
require "dcb_event_store"
require "dcb_event_store/web/read_model"
require "dcb_event_store/web/router"

module DcbEventStore
  module Web
    class << self
      # A store/connection provider set by the host app. Accepts either a raw
      # `pg` connection or a callable returning one. When unset, falls back to
      # ActiveRecord's connection if ActiveRecord is loaded.
      attr_writer :connection

      # The namespaces the browser offers (names; nil or "" is the default).
      # Unset, they are discovered from the database's "<name>_events" tables
      # on each request.
      def namespaces=(names)
        @namespaces = names&.map { |name| name.to_s.empty? ? nil : Namespace.wrap(name).name }
      end

      def connection
        return @connection.call if @connection.respond_to?(:call)
        return @connection if @connection

        active_record_connection
      end

      # The Rack entry point: `mount DcbEventStore::Web => "/dcb"` (Rails) or
      # `run DcbEventStore::Web` (config.ru).
      def call(env)
        conn = connection
        Router.new(->(namespace) { ReadModel.new(conn, namespace: namespace) },
                   namespaces: -> { available_namespaces(conn) }).call(env)
      end

      private

      # An empty database has no tables to discover; offer the default
      # namespace anyway, so the page reports what is missing.
      def available_namespaces(conn)
        return @namespaces if @namespaces

        found = ReadModel.namespaces(conn)
        found.empty? ? [nil] : found
      end

      def active_record_connection
        return unless defined?(ActiveRecord::Base)

        ActiveRecord::Base.connection.raw_connection
      end
    end
  end
end
