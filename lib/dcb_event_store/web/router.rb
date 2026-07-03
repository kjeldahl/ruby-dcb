require "uri"
require "dcb_event_store/web/list_params"
require "dcb_event_store/web/view"

module DcbEventStore
  module Web
    # Minimal request router for the browser. Maps the two v1 routes - the event
    # list ("/") and a single event ("/events/:position") - to a rendered View,
    # everything else to 404. Parses query params with stdlib URI (no Rack
    # dependency in the gem) and delegates their interpretation to ListParams.
    # The mount prefix (SCRIPT_NAME) is threaded into views as +base+ so links
    # are correct wherever the app is mounted. Performs no writes.
    class Router
      HTML_HEADERS = { "content-type" => "text/html; charset=utf-8" }.freeze

      def initialize(read_model)
        @read = read_model
      end

      def call(env)
        base = env["SCRIPT_NAME"].to_s
        case env["PATH_INFO"]
        when "", "/"
          list(env, base)
        when %r{\A/events/(\d+)\z}
          detail(Regexp.last_match(1).to_i, base)
        else
          not_found(base)
        end
      end

      private

      def list(env, base)
        params = ListParams.new(URI.decode_www_form(env["QUERY_STRING"].to_s))
        query = params.query

        ok View.render("list",
                       base: base,
                       params: params,
                       events: @read.page(query: query, limit: params.per_page, offset: params.offset),
                       total: @read.count(query),
                       types: @read.event_types)
      end

      def detail(position, base)
        event = @read.find(position)
        return not_found(base) unless event

        ok View.render("event", base: base, event: event)
      end

      def ok(body)
        [200, HTML_HEADERS.dup, [body]]
      end

      def not_found(base)
        [404, HTML_HEADERS.dup, [View.render("not_found", base: base)]]
      end
    end
  end
end
