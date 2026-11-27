module SiteAudits
  class ListingPage
    include PublicPageReader

    def self.call(**options)
      new(**options).call
    end

    def initialize(host:, url:, fetcher: Fetcher.new, sleeper: ->(seconds) { sleep(seconds) })
      @scope = PublicUrl.new(host, https_only: true)
      @uri = @scope.resolve(url, base: url) if Tracking::ResultUrl.parse(url)
      @fetcher, @sleeper = fetcher, sleeper
    end

    def call
      result = { "status" => "unavailable", "url" => @uri&.to_s,
        "checked_at" => Time.current.utc.iso8601, "title" => nil, "description" => nil, "h1" => nil }
      raise Stop, "Choose a public HTTPS page on this website." unless @uri

      start_requests(request_limit: 10, time_limit: 22)
      page = read_public_page(@uri, "website")
      result["url"] = page.uri.to_s
      document = readable_html(page, "website")
      result.merge!(self.class.metadata(document))
      result.merge("status" => "observed",
        "excerpts" => sample_text(document, "body p", length: 35..300, limit: 12),
        "headings" => sample_text(document, "body h2, body h3", length: 2..150, limit: 16))
    rescue Stop, Fetcher::Error => error
      result.merge("reason" => error.message)
    rescue URI::Error, Nokogiri::XML::SyntaxError, EncodingError
      result.merge("reason" => "The public page returned markup that could not be read.")
    end

    def self.metadata(document)
      result = {"field_states" => {}}
      tags = {
        "title" => document.css("head > title"),
        "description" => document.css("head > meta[name]").select { |node| node["name"].strip.casecmp?("description") },
        "h1" => document.css("body h1")
      }
      tags.each do |field, nodes|
        state, value = field_value(field, nodes)
        result["field_states"][field] = state
        result[field] = value
      end
      result
    end

    def self.field_value(field, nodes)
      return ["missing", nil] if nodes.empty?
      return ["multiple", nil] if nodes.size > 1
      value = (field == "description" ? nodes.first["content"] : nodes.first.text).to_s.squish
      return ["empty", nil] if value.blank?
      return ["too_long", nil] if value.size > 2000
      ["present", value]
    end

    private_class_method :field_value

    private

    def sample_text(document, selector, length:, limit:)
      document.css(selector).lazy.reject do |node|
        node.ancestors.any? do |ancestor|
          %w[nav footer header aside form blockquote].include?(ancestor.name) ||
            %w[banner navigation contentinfo complementary menu].include?(ancestor["role"])
        end
      end.map { |node| node.text.squish }.select { |text| length.cover?(text.size) }.uniq.first(limit)
    end
  end
end
