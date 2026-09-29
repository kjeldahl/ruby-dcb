require "uri"
require "dcb_event_store/web/list_params"
require "dcb_event_store/web/view"

module DcbEventStore
  module Web
    # Minimal request router for the browser. Maps the routes - the event list
    # ("/"), a single event ("/events/:position"), the snapshot list
    # ("/snapshots") and a single snapshot ("/snapshot?key=") - to a rendered
    # View, everything else to 404. Every route reads one namespace, chosen by
    # the "ns" param among +namespaces+ (names, nil for the default; an
    # Array or a callable returning one); +read_models+ is a callable turning
    # a namespace into the ReadModel that reads it. Parses query params with
    # stdlib URI (no Rack dependency in the gem) and delegates their
    # interpretation to ListParams. The mount prefix (SCRIPT_NAME) is threaded
    # into views as +base+ so links are correct wherever the app is mounted.
    # Performs no writes.
    class Router
      HTML_HEADERS = { "content-type" => "text/html; charset=utf-8" }.freeze

      def initialize(read_models, namespaces: [nil])
        @read_models = read_models
        @namespaces = namespaces
      end

      def call(env)
        base = env["SCRIPT_NAME"].to_s
        params = ListParams.new(URI.decode_www_form(env["QUERY_STRING"].to_s))
        available = @namespaces.respond_to?(:call) ? @namespaces.call : @namespaces
        namespace = params.namespace(available)
        return not_found(base) unless available.include?(namespace)

        scope = { base: base, namespace: namespace, namespaces: available }
        read = @read_models.call(namespace)
        case env["PATH_INFO"]
        when "", "/"
          list(read, params, scope)
        when %r{\A/events/(\d+)\z}
          detail(read, Regexp.last_match(1).to_i, scope)
        when "/snapshots"
          snapshots(read, params, scope)
        when "/snapshot"
          snapshot(read, params, scope)
        else
          not_found(base)
        end
      end

      private

      def list(read, params, scope)
        query = params.query

        ok View.render("list",
                       **scope,
                       params: params,
                       events: read.page(query: query, limit: params.per_page, offset: params.offset),
                       total: read.count(query),
                       types: read.event_types)
      end

      def detail(read, position, scope)
        event = read.find(position)
        return not_found(scope[:base]) unless event

        ok View.render("event", **scope, event: event)
      end

      def snapshots(read, params, scope)
        return ok View.render("snapshots", **scope, params: params, available: false) unless read.snapshots?

        ok View.render("snapshots",
                       **scope,
                       params: params,
                       available: true,
                       head: read.head_position,
                       snapshots: read.snapshot_page(match: params.match, limit: params.per_page,
                                                     offset: params.offset),
                       total: read.snapshot_count(match: params.match))
      end

      def snapshot(read, params, scope)
        record = read.snapshots? && read.find_snapshot(params.key)
        return not_found(scope[:base]) unless record

        ok View.render("snapshot", **scope, snapshot: record, head: read.head_position,
                                            event_found: !read.find(record.position).nil?)
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
