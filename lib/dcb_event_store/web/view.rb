require "erb"
require "json"
require "cgi"
require "uri"

module DcbEventStore
  module Web
    # Renders an ERB template inside the shared layout, exposing assigns as
    # methods plus escaping/formatting/link helpers. Templates live in
    # web/views/. All dynamic text must go through #h - ERB here does not
    # auto-escape. Links are built from +base+ (the mount prefix) so they are
    # correct wherever the app is mounted.
    class View
      TEMPLATES = File.expand_path("views", __dir__)

      def self.render(template, assigns = {})
        new(template, assigns).render
      end

      def initialize(template, assigns)
        @template = template
        @assigns = assigns
      end

      def render
        @content = render_template(@template)
        render_template("layout")
      end

      # --- text helpers ---

      attr_reader :content

      def h(text)
        CGI.escapeHTML(text.to_s)
      end

      def pretty_json(data)
        JSON.pretty_generate(data)
      end

      def short(id)
        id.to_s[0, 8]
      end

      def format_time(time)
        time.strftime("%Y-%m-%d %H:%M:%S")
      end

      # --- link helpers (mount-aware) ---

      def base
        @assigns.fetch(:base, "").to_s
      end

      def root_url
        "#{base}/"
      end

      def event_url(position)
        "#{base}/events/#{position}"
      end

      # A list URL for an explicit filter. Omits default/empty parts so URLs
      # stay tidy; repeated tags accumulate as separate "tag" params.
      def filter_url(type:, tags:, page: 1, per_page: nil)
        pairs = []
        pairs << ["type", type] unless type.to_s.empty?
        tags.each { |tag| pairs << ["tag", tag] }
        pairs << ["per_page", per_page] if per_page && per_page != ListParams::DEFAULT_PER_PAGE
        pairs << ["page", page] if page > 1
        query = URI.encode_www_form(pairs)
        query.empty? ? root_url : "#{root_url}?#{query}"
      end

      # Links relative to the current list filter (list page; uses +params+).
      def page_url(page)
        filter_url(type: params.selected_type, tags: params.tags, page: page, per_page: params.per_page)
      end

      def add_tag_url(tag)
        filter_url(type: params.selected_type, tags: (params.tags + [tag]).uniq, per_page: params.per_page)
      end

      def remove_tag_url(tag)
        filter_url(type: params.selected_type, tags: params.tags - [tag], per_page: params.per_page)
      end

      # A fresh list filtered by a single tag (used from the detail page).
      def tag_url(tag)
        filter_url(type: "", tags: [tag])
      end

      private

      def render_template(name)
        template = File.read(File.join(TEMPLATES, "#{name}.erb"))
        ERB.new(template, trim_mode: "-").result(binding)
      end

      def method_missing(name, *args)
        return @assigns.fetch(name) if @assigns.key?(name)

        super
      end

      def respond_to_missing?(name, include_private = false)
        @assigns.key?(name) || super
      end
    end
  end
end
