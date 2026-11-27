module CompetingPages
  class ListingCheck
    class Stale < StandardError; end
    class Busy < StandardError; end

    def self.target_for(finding)
      last_leader = Array(finding.evidence["weeks"]).reverse_each.find { |week| week["state"] == "leader" }
      url = last_leader&.fetch("leader_url", nil)
      Comparison.public_page(url, finding.site.host) if url && Array(finding.evidence["pages"]).include?(url)
    end

    def self.saved(finding)
      new(finding).saved
    end

    def self.call(finding:, version:)
      new(finding).run(version)
    end

    def initialize(finding, listing_reader: Tracking::ListingEvidence, page_reader: SiteAudits::ListingPage)
      @finding, @listing_reader, @page_reader = finding, listing_reader, page_reader
    end

    def saved
      key = evidence_key
      report = @finding.listing_check
      report if key && report && report["evidence_key"] == key
    end

    def run(version)
      ListingRefresh.call(finding: @finding, version: version, identity: method(:evidence_key)) do |key|
        report = build(key, self.class.target_for(@finding))
        previous = @finding.listing_check
        if previous && previous["evidence_key"] == key && previous["article_check"]
          report["article_check"] = previous["article_check"]
        end
        report
      end
    end

    private

    def build(key, target)
      google = @listing_reader.call(keyword: @finding.keyword, device: @finding.evidence.fetch("device"), url: target)
      page = @page_reader.call(host: @finding.site.host, url: target)
      if page["status"] == "observed" && !Tracking::ResultUrl.same_page?(target, page["url"])
        page = page.slice("url", "checked_at").merge("status" => "unavailable",
          "reason" => "The address redirected to a different page. Confirm the intended address before editing.")
      end
      comparison = %w[title description].index_with do |field|
        next "not_comparable" unless google["status"] == "observed" && Tracking::ResultUrl.same_page?(google["url"], target) &&
          page["status"] == "observed" && google[field].present? && page[field].present?
        google[field].squish == page[field].squish ? "matches" : "different"
      end
      draft = ListingDraft.new(site: @finding.site, page: page, target: target, google: google).call
      {"evidence_key" => key, "checked_at" => Time.current.utc.iso8601, "target_url" => target,
        "google" => google, "page" => page.except("excerpts", "headings"), "comparison" => comparison, "draft" => draft}
    end

    def evidence_key
      site, keyword = @finding.site, @finding.keyword
      connection = site.search_console_connection
      e = @finding.evidence
      return unless @finding.active? && @finding.kind == "competing_pages" && keyword && keyword.site_id == site.id &&
        keyword.phrase.casecmp?(e["query"].to_s) && %w[desktop mobile].include?(e["device"]) &&
        %w[connected delayed].include?(connection&.status) && e["property"] == connection.property &&
        SearchConsole::Client.matches?(connection.property, site.host) && e["country"] == SearchConsole::DailyPositions.country_for(site)
      target = self.class.target_for(@finding)
      return unless target
      series = keyword.tracking_series.current.find_by(device: e["device"], source: "dataforseo")
      latest = if series
        series.rank_observations.joins(:daily_slot).where(source: "dataforseo")
          .order("daily_slots.day DESC").limit(1).pick("rank_observations.id", :captured_at, :coverage, :position)
      end
      Digest::SHA256.hexdigest(JSON.generate([1, site.id, site.host, site.name, site.location, site.language, site.rank_location_code,
        keyword.id, e.values_at("query", "property", "country", "device", "pages"), e.dig("clicks", "current_end"), target, series&.id, latest]))
    end
  end
end
