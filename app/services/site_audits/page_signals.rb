module SiteAudits
  class PageSignals
    include PublicPageReader

    def initialize(uri, fetcher: Fetcher.new, sleeper: ->(seconds) { sleep(seconds) })
      @uri, @fetcher, @sleeper = uri, fetcher, sleeper
      @scope = PublicUrl.new(uri.host, https_only: true)
    end

    def call
      result = { "url" => @uri.to_s, "status" => "unavailable" }
      start_requests(request_limit: 8, time_limit: 36)
      page = read_public_page(@uri, "comparison")
      result["url"] = page.uri.to_s
      document = readable_html(page, "comparison") do |raw_document|
        result["storefront_markup"] = LocalBusinessMarkup.extract(raw_document, page.uri.to_s, @uri.host).present?
      end
      fields = ListingPage.metadata(document).fetch("field_states")
      main = document.css("main, [role='main']")
      if main.one?
        main.first.css("nav, footer, aside, form, [role='navigation']").remove
        result["main_headings"] = main.first.css("h2, h3").count { |heading| heading.text.squish.present? }
        result["main_words"] = main.first.xpath(".//text()").sum { |text| text.content.scan(/[[:alnum:]]+/).size }
      end
      result.merge("status" => "observed", "fields" => fields)
    rescue Stop, Fetcher::Error => error
      result.except("storefront_markup").merge("reason" => error.message)
    rescue URI::Error, Nokogiri::XML::SyntaxError, EncodingError
      result.except("storefront_markup").merge("reason" => "The public page returned markup that could not be read.")
    end
  end
end
