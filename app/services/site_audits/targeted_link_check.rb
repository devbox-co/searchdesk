module SiteAudits
  class TargetedLinkCheck
    include PublicPageReader

    REQUEST_LIMIT = 10
    TIME_LIMIT = 22
    MAX_LINKS = 1500
    CONTENT = "article, main, [role=main], .entry-content, .post-content, .page-content"
    LANDMARKS = {
      "Navigation" => "nav, [role=navigation], [role=menu], [role=menubar], .menu, .sub-menu, .breadcrumb, .breadcrumbs, .pagination",
      "Footer" => "footer, [role=contentinfo], .site-footer",
      "Header" => "header, [role=banner], .site-header",
      "Sidebar" => "aside, [role=complementary], .sidebar, .widget-area"
    }.freeze

    def initialize(host:, source_url:, target_url:, fetcher: Fetcher.new, sleeper: ->(duration) { sleep(duration) }, https_only: false)
      @scope = PublicUrl.new(host, https_only: https_only)
      @source = absolute_page(source_url)
      @target = absolute_page(target_url)
      @fetcher, @sleeper = fetcher, sleeper
    end

    def call
      start_requests(request_limit: REQUEST_LIMIT, time_limit: TIME_LIMIT)
      @evidence = { "source_url" => @source&.to_s, "target_url" => @target&.to_s }.compact
      raise Stop, "Both addresses must identify public pages on this website." unless @source && @target

      source = read_page(@source, "ranking")
      document = readable_html(source, "ranking")
      check_target(document, source)
    rescue Stop, Fetcher::Error => error
      @evidence.merge("outcome" => "unverifiable", "reason" => error.message)
    rescue URI::Error, Nokogiri::XML::SyntaxError
      @evidence.merge("outcome" => "unverifiable", "reason" => "The website returned page markup or a link address that could not be read.")
    end

    private

    def absolute_page(value)
      return unless Tracking::ResultUrl.parse(value)
      @scope.resolve(value, base: value)
    end

    def read_page(uri, label)
      page = read_public_page(uri, label)
      key = label == "chosen" ? "target" : "source"
      @evidence["final_#{key}_url"] = page.uri.to_s
      @evidence["#{key}_status"] = page.response.status
      page
    end

    def check_target(document, source)
      target = read_page(@target, "chosen")
      return @evidence.merge("outcome" => "broken_target") if [404, 410].include?(target.response.status)
      readable_html(target, "chosen")
      if source.visited.intersect?(target.visited)
        raise Stop, "Both addresses lead to the same page. Check which destination you want to use."
      end
      if target.uri.path == "/" && @target.path != "/"
        raise Stop, "The chosen address now redirects to the homepage. Confirm the intended destination."
      end

      locate_link(document, source.uri, target)
    end

    def locate_link(document, source, target)
      base = URI.join(source, document.at_css("head base[href]")&.[]("href").to_s)
      @landmarks = {}
      landmark_selectors.each do |name, selector|
        document.css(selector).each { |node| @landmarks[node] ||= name }
      end
      @content = document.css(CONTENT).to_set
      navigation = nil
      uncertain = false
      document.css("body a[href]").each_with_index do |link, index|
        raise Stop, "The page contains more links than this check can inspect." if index >= MAX_LINKS
        address = @scope.resolve(link["href"], base: base)
        unless address && target.visited.include?(address.to_s)
          uncertain ||= possible_variant?(link["href"], base, target)
          next
        end
        words = link.text.squish.presence || link["aria-label"].to_s.squish.presence || link.at_css("img[alt]")&.[]("alt").to_s.squish.presence
        placement = landmark(link)
        if words && (placement || in_content?(link))
          evidence = { "anchor" => words.first(220), "placement" => placement || "Article text", "linked_url" => address.to_s }
          if placement
            navigation ||= evidence
          else
            return @evidence.merge(evidence, "outcome" => "contextual", "section" => previous_heading(link)).compact
          end
        else
          uncertain = true
        end
      end
      if uncertain
        raise Stop, "A possible link was found, but its destination, wording or placement could not be verified."
      end
      raise Stop, "The main text of the ranking page could not be verified from its public HTML." unless readable_prose?(document)
      return @evidence.merge(navigation, "outcome" => "navigation_only") if navigation
      @evidence.merge("outcome" => "missing")
    end

    def landmark_selectors
      LANDMARKS
    end

    def readable_prose?(document)
      document.css("body p, body li, body dd, body blockquote").any? do |node|
        !landmark(node) && node.text.squish.length >= 20
      end
    end

    def in_content?(node)
      node.ancestors.any? { |ancestor| @content.include?(ancestor) || %w[p blockquote dd].include?(ancestor.name) }
    end

    def landmark(node)
      node.ancestors.each { |ancestor| return @landmarks[ancestor] if @landmarks.key?(ancestor) }
      nil
    end

    def previous_heading(link)
      root = link.ancestors.find { |node| @content.include?(node) } || link.document.at_css("body")
      heading = link.xpath("preceding::*[self::h1 or self::h2 or self::h3 or self::h4 or self::h5 or self::h6][1]").first
      if heading && heading.ancestors.include?(root) && !landmark(heading)
        heading.text.squish.first(160).presence
      end
    end

    # A trailing slash, a query, or another origin variant can name a genuinely different resource.
    # Only a visited address in the chosen page's verified redirect chain establishes a working link.
    def possible_variant?(href, base, target)
      return false if href.blank? || href.start_with?("#")
      candidate = URI.join(base, href)
      return false unless candidate.is_a?(URI::HTTP) && Tracking::ResultUrl.host_matches?(@target.host, candidate.host)
      target.visited.any? { |address| URI(address).path.delete_suffix("/") == candidate.path.delete_suffix("/") }
    rescue URI::Error
      false
    end
  end
end
