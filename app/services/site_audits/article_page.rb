module SiteAudits
  class ArticlePage < TargetedLinkCheck
    ARTICLE_AREAS = ["[itemprop~='articleBody'], .entry-content, .post-content, .wp-block-post-content",
      "article, .hentry", "main, [role=main]"].freeze
    POST_DETAILS = ".entry-meta, .post-meta, .postmetadata, .post-tags, .entry-footer, .post-navigation, " \
      ".wp-block-post-author, .wp-block-post-terms, .author-box, [itemprop=author], .related-posts, .comments-area, " \
      "[rel~=author], [rel~=tag], form, figcaption, blockquote"

    ARTICLE_LANDMARKS = LANDMARKS.merge("Navigation" => "#{LANDMARKS.fetch("Navigation")}, .wp-block-navigation, .nav-menu",
      "Post details" => POST_DETAILS).freeze

    def self.call(**options)
      new(**options).call
    end

    def initialize(host:, url:, homepage:, **options)
      super(host: host, source_url: url, target_url: homepage, https_only: true, **options)
    end

    def call
      start_requests(request_limit: REQUEST_LIMIT, time_limit: TIME_LIMIT)
      @evidence = {"source_url" => @source&.to_s, "target_url" => @target&.to_s}
      hops = []
      page = {"status" => "unavailable", "url" => @source&.to_s, "checked_at" => Time.current.utc.iso8601, "redirects" => hops}
      raise Stop, "Choose a public article address on this website." unless @source

      source = read_public_page(@source, "ranking") do |from, status, to|
        hops << {"url" => from.to_s, "status" => status, "location" => to.to_s}
      end
      @evidence.merge!("final_source_url" => source.uri.to_s, "source_status" => source.response.status)
      if !Tracking::ResultUrl.same_page?(@source.to_s, source.uri.to_s)
        page["status"] = "redirected"
        page["destination"] = {"url" => source.uri.to_s, "http_status" => source.response.status, "status" => "unavailable"}
      end
      document = readable_html(source, "ranking")
      @area = article_area(document)
      @noneditorial = document.css(ARTICLE_LANDMARKS.values.join(", ")).to_set
      fields = ListingPage.metadata(document).merge("status" => "observed", "canonical" => canonical(document, source.uri),
        "headings" => article_text("h2, h3").first(16).filter_map { |text| bounded_text(text, 180) })
      if page["destination"]
        page["destination"].merge!(fields)
        return {"page" => page, "link" => @evidence.merge("outcome" => "source_redirected")}
      end

      paragraphs = article_text("p").select { |text| text.size >= 20 }
      page.merge!(fields, "http_status" => source.response.status, "opening" => bounded_text(paragraphs.first, 1500),
        "paragraphs" => paragraphs.first(20).filter_map { |text| bounded_text(text, 1500) })
      raise Stop, "Choose this website’s public homepage." unless @target && @target.path == "/"
      {"page" => page, "link" => check_target(document, source)}
    rescue Stop, Fetcher::Error, URI::Error, Nokogiri::XML::SyntaxError, EncodingError => error
      reason = error.is_a?(Stop) || error.is_a?(Fetcher::Error) ? error.message : "The website returned markup this check could not read."
      if page["destination"]
        page["destination"]["reason"] = reason
        outcome = "source_redirected"
      else
        page["reason"] = reason unless page["status"] == "observed"
        outcome = "unverifiable"
      end
      {"page" => page, "link" => @evidence.merge("outcome" => outcome, "reason" => reason)}
    end

    private

    def canonical(document, uri)
      links = document.css("head link[rel]").select { |link| link["rel"].downcase.split.include?("canonical") }
      return unless links.one? && links.first["href"].present?
      base = URI.join(uri, document.at_css("head base[href]")&.[]("href").to_s)
      @scope.resolve(links.first["href"], base: base)&.to_s
    end

    def article_area(document)
      ARTICLE_AREAS.each do |selector|
        nodes = document.css(selector)
        return nodes.first if nodes.one?
        return if nodes.many?
      end
      nil
    end

    def article_text(selector)
      return [] unless @area
      @area.css(selector).reject { |node| outside_editorial_text?(node) }.map { |node| node.text.squish }.reject(&:empty?)
    end

    def bounded_text(text, limit)
      text if text.present? && text.size <= limit
    end

    def outside_editorial_text?(node)
      @noneditorial.include?(node) || node.ancestors.any? { |ancestor| @noneditorial.include?(ancestor) }
    end

    def landmark_selectors
      ARTICLE_LANDMARKS
    end

    def landmark(node)
      @landmarks[node] || super
    end

    def in_content?(node)
      parents = node.ancestors.take_while { |ancestor| ancestor != @area }
      @area && node.ancestors.include?(@area) && parents.any? { |ancestor| %w[p li dd].include?(ancestor.name) } &&
        !outside_editorial_text?(node)
    end

    def readable_prose?(_document)
      @area && @area.css("p, li, dd").any? { |p| !outside_editorial_text?(p) && p.text.squish.size >= 20 }
    end
  end
end
