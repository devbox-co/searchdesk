require "nokogiri"

module SiteAudits
  class Crawler
    PAGE_LIMIT = 20
    REQUEST_LIMIT = 28
    TIME_LIMIT = 120
    DISCOVERY_LIMIT = 400
    MIN_DELAY = 0.5
    HTML = %w[text/html application/xhtml+xml].freeze
    REDIRECTS = [301, 302, 303, 307, 308].freeze
    CHECKS = {
      "missing_title" => ["Missing page title", "Add a descriptive title that identifies the page's purpose."],
      "duplicate_title" => ["Repeated page title", "Check these pages together and give distinct pages distinct titles."],
      "missing_description" => ["Missing meta description", "Write a short summary for pages where an accurate search snippet matters."],
      "missing_h1" => ["Missing main heading", "Give the page a visible main heading describing its topic."],
      "multiple_h1" => ["Multiple main headings", "Review the heading structure and identify the main topic."],
      "missing_canonical" => ["Missing canonical link", "Check whether this page has alternative URLs and needs a preferred URL."],
      "noindex" => ["Indexing disabled", "Confirm whether the page should appear in search before changing its indexing directive."],
      "http_error" => ["HTTP error", "Inspect the URL and fix its response or update the links pointing to it."],
      "broken_link" => ["Link leads to an HTTP error", "Replace or remove internal links to the error URLs found in this sample."],
      "fetch_error" => ["Page could not be read", "Check availability, TLS and response size before rerunning the crawl."],
      "redirect_unfollowed" => ["Redirect outside crawl scope", "Review the redirect destination and confirm it is intentional."]
    }.freeze
    class Stop < StandardError; end

    def initialize(host:, fetcher: Fetcher.new, sleeper: ->(duration) { sleep(duration) })
      @start = URI("https://#{host}/")
      @scope = PublicUrl.new(host)
      @fetcher, @sleeper = fetcher, sleeper
      @frontier = [@start]
      @discovered = Set[@start.to_s]
      @visited, @blocked = Set.new, Set.new
      @policies, @outgoing, @pages = {}, {}, []
      @requests = 0
      @delay = MIN_DELAY
    end

    def call
      @deadline = clock + TIME_LIMIT
      while @frontier.any? && @pages.size < PAGE_LIMIT
        uri = @frontier.shift
        next unless @visited.add?(uri.to_s)
        if policy_for(uri).allowed?(uri.path)
          inspect_page(uri)
        else
          @blocked << uri.to_s
        end
      end
      complete_report(@frontier.any? ? "Completed the #{PAGE_LIMIT}-URL sample." : nil, completed: true)
    rescue Stop => error
      complete_report(error.message)
    end

    private

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def fetch(uri, robots: false)
      raise Stop, "Reached the request limit for this crawl." if @requests >= REQUEST_LIMIT
      # Leave enough time for the complete bounded network request.
      raise Stop, "Reached the time limit for this crawl." if clock + @delay + 12 > @deadline
      @sleeper.call(@delay) unless @requests.zero?
      @requests += 1
      @fetcher.get(uri, robots: robots)
    end

    def policy_for(uri)
      origin = "#{uri.scheme}://#{uri.host}"
      @policies[origin] ||= begin
        target = @scope.resolve("/robots.txt", base: origin, robots: true)
        visited = Set.new
        raise Stop, "The site address is outside the public crawl scope." unless target
        rules = loop do
          raise Stop, "Could not confirm robots.txt after redirects." unless visited.size < 6 && visited.add?(target.to_s)
          response = fetch(target, robots: true)
          case response.status
          when 200..299
            raise Stop, "Could not read robots.txt because the server returned HTML." if response.body.lstrip.start_with?("<")
            break Robots.new(response.body)
          when 404, 410
            break Robots.new("")
          when *REDIRECTS
            target = @scope.resolve(response.location, base: target, robots: true)
            raise Stop, "The robots.txt redirect left this site's crawl scope." unless target
          else
            raise Stop, "The server returned HTTP #{response.status} for robots.txt. The crawl stopped."
          end
        end
        raise Stop, "The site's requested crawl delay exceeds the audit time budget." if rules.delay > 10
        @delay = [@delay, rules.delay].max
        rules
      end
    rescue Robots::Unreadable
      raise Stop, "The robots.txt rules exceed the supported audit limits."
    rescue Fetcher::Error => error
      raise Stop, "Could not confirm robots.txt. #{error.message}"
    end

    def inspect_page(uri)
      row = { "url" => uri.to_s, "path" => uri.path, "status" => nil, "issues" => [] }
      @pages << row
      response = fetch(uri)
      row["status"] = response.status
      case response.status
      when 200..299
        inspect_html(uri, row, response) if HTML.include?(response.content_type)
      when *REDIRECTS
        target = @scope.resolve(response.location, base: uri)
        if target
          row["redirect_to"] = target.path
          discover(target, priority: true)
        else
          row["issues"] << "redirect_unfollowed"
        end
      when 400..599
        row["issues"] << "http_error"
      end
      raise Stop, "The server asked the crawler to slow down. Try again later." if [429, 503].include?(response.status)
    rescue Fetcher::Error => error
      row["issues"] << "fetch_error"
      row["detail"] = error.message
    rescue Stop
      @pages.delete(row) unless row["status"]
      raise
    end

    def inspect_html(uri, row, response)
      document = if response.content_type == "application/xhtml+xml"
        Nokogiri::XML(response.body) { |options| options.nonet }.remove_namespaces!
      else
        Nokogiri::HTML4(response.body)
      end
      row["html"] = true
      row["title"] = document.at_css("head title")&.text.to_s.squish.first(220)
      row["h1_count"] = document.css("h1").count { |h| h.text.present? }
      metas = document.css("head meta[name]").group_by { |tag| tag["name"].to_s.downcase }
      row["issues"] << "missing_title" if row["title"].blank?
      row["issues"] << "missing_description" unless metas.fetch("description", []).any? { |tag| tag["content"].present? }
      row["issues"] << "missing_h1" if row["h1_count"].zero?
      row["issues"] << "multiple_h1" if row["h1_count"] > 1
      canonical = document.css("head link[rel][href]").any? { |link| link["rel"].downcase.split.include?("canonical") && link["href"].present? }
      row["issues"] << "missing_canonical" unless canonical
      directives = metas.values_at("robots", "googlebot").compact.flatten.map { |tag| tag["content"] }
      # Scope agent-specific X-Robots-Tag fields to Google's web agent or to all agents.
      header = response.robots_header.split(/,\s*(?=[\w-]+\s*:)/).filter_map do |entry|
        prefix, value = entry.strip.split(/:\s*/, 2)
        value ? (value if prefix.casecmp?("googlebot")) : prefix
      end
      row["issues"] << "noindex" if (header + directives).join(",").match?(/(?:\A|[\s,])(?:noindex|none)(?:\z|[\s,])/i)
      robots_values = directives.compact.join(",") + "," + header.join(",")
      nofollow = robots_values.match?(/(?:\A|[\s,])(?:nofollow|none)(?:\z|[\s,])/i)
      # A base element may point off-site. Resolve against it, then apply the same-site check to each result.
      base = URI.join(uri, document.at_css("head base[href]")&.[]("href").to_s)
      outgoing = Set.new
      document.css("a[href]").each do |a|
        target = @scope.resolve(a["href"], base: base)
        next unless target
        outgoing << target.to_s
        discover(target) unless nofollow || a["rel"].to_s.downcase.split.include?("nofollow")
        break if outgoing.size >= DISCOVERY_LIMIT
      end
      row["internal_links"] = outgoing.size
      @outgoing[uri.to_s] = outgoing
    rescue URI::Error
      row["internal_links"] = 0
    end

    def discover(target, priority: false)
      return if @discovered.size >= DISCOVERY_LIMIT || !@discovered.add?(target.to_s)
      priority ? @frontier.unshift(target) : @frontier << target
    end

    def complete_report(reason, completed: false)
      @pages.select { |p| p["title"].present? }.group_by { |p| p["title"].downcase }.each_value do |copies|
        copies.each { |p| p["issues"] << "duplicate_title" } if copies.many?
      end
      errors = @pages.select { |p| p["status"].to_i >= 400 }.pluck("url").to_set
      @pages.each do |page|
        broken = @outgoing.fetch(page["url"], Set.new).intersection(errors)
        if broken.any?
          page["issues"] << "broken_link"
          page["broken_links"] = broken.map { |u| URI(u).path }
        end
      end
      issues = CHECKS.filter_map do |code, (label, advice)|
        affected = @pages.select { |p| p["issues"].include?(code) }
        { "code" => code, "label" => label, "advice" => advice, "count" => affected.size, "paths" => affected.pluck("path") } if affected.any?
      end
      fetch_errors = @pages.count { |page| page["issues"].include?("fetch_error") }
      html_pages = @pages.count { |page| page["html"] }
      status = if @pages.empty? || fetch_errors == @pages.size
        reason ||= @blocked.include?(@start.to_s) ? "The homepage is disallowed by robots.txt." : "No page could be fetched."
        "failed"
      elsif !completed || fetch_errors.positive?
        "partial"
      else
        "complete"
      end
      { "status" => status, "stop_reason" => reason, "summary" => {
        "pages_checked" => @pages.size, "html_pages" => html_pages, "redirects" => @pages.count { |p| REDIRECTS.include?(p["status"]) },
        "http_errors" => errors.size, "fetch_errors" => fetch_errors, "robots_blocked" => @blocked.size,
        "issues" => @pages.sum { |p| p["issues"].size }, "pages_with_issues" => @pages.count { |p| p["issues"].any? },
        "discovered_urls" => @discovered.size, "request_count" => @requests, "page_limit" => PAGE_LIMIT
      }, "issues" => issues, "pages" => @pages }
    end
  end
end
