module CompetingPages
  class ArticleCheck
    Stale = ListingCheck::Stale
    Busy = ListingCheck::Busy

    def self.candidate(finding)
      receipt = ListingCheck.saved(finding)
      return unless receipt
      google = receipt["google"]
      return unless google["status"] == "target_not_seen" && google["keyword"].to_s.casecmp?(finding.keyword.phrase) &&
        google["device"] == finding.evidence["device"] && google["observation_id"].is_a?(Integer) && google["captured_at"].present?
      item = google["other_result"]
      return unless item && item["position"].is_a?(Integer) && item["position"].between?(1, google["coverage"].to_i)
      url = item["url"]
      scope = SiteAudits::PublicUrl.new(finding.site.host, https_only: true)
      return unless Tracking::ResultUrl.parse(url) && scope.resolve(url, base: url)&.to_s == url &&
        !Tracking::ResultUrl.same_page?(url, receipt["target_url"]) && URI(url).path != "/"
      fields = google.slice("keyword", "source", "device", "os", "language", "location", "captured_at", "observation_id", "coverage")
        .merge(item.slice("url", "position", "title", "description"), "status" => "observed")
      key = Digest::SHA256.hexdigest(JSON.generate([1, receipt.fetch("evidence_key"), fields.sort]))
      fields.merge("capture_key" => key)
    end

    def self.saved(finding)
      report = finding.listing_check&.fetch("article_check", nil)
      return unless report && report["capture_key"] == candidate(finding)&.fetch("capture_key")
      report
    end

    def self.call(finding:, version:, capture_key:, reader: SiteAudits::ArticlePage)
      identity = -> { candidate(finding)&.fetch("capture_key") }
      receipt = ListingRefresh.call(finding:, version:, identity:) do |key|
        raise Stale unless key == capture_key
        current = candidate(finding)
        raise Stale unless current && current["capture_key"] == key
        google = current.except("capture_key")
        site = finding.site
        homepage = "https://#{site.host}/"
        page, link = reader.call(host: site.host, url: google.fetch("url"), homepage: homepage).values_at("page", "link")
        archive = ArticleArchive.call(site:, google:, page:)
        draft = ArticleDraft.call(site:, page:, google:, link:, homepage:)
        if archive
          title = archive.dig("comparison", "title")
          notes = ["Original page copy from #{archive.fetch('captured_at')}."]
          notes << "Google showed the beginning of the archived title, shortened with an ellipsis." if title == "truncated"
          if archive["snippet_in_body"] && archive.dig("comparison", "description") == "different"
            notes << "The captured snippet matches wording in the archived article body and differs from its meta description."
          end
          if (prior = archive["prior_redirect"])
            notes << "The same HTTP #{prior['status']} redirect was recorded on #{prior['captured_at']}, before this Google result."
          end
          draft = draft.merge("instructions" => [draft.fetch("instructions"), notes.join(" ")].join("\n\n"))
        end
        checked = {"capture_key" => key, "checked_at" => Time.current.utc.iso8601,
          "target_url" => google.fetch("url"), "homepage_url" => homepage, "google" => google, "page" => compact_page(page),
          "comparison" => ArticleComparison.fields(google, page), "link" => link, "draft" => draft, "archive" => archive}
        finding.listing_check.merge("article_check" => checked)
      end
      receipt.fetch("article_check")
    end

    def self.compact_page(page)
      metadata = page.except("excerpts", "headings", "paragraphs", "opening")
      destination = page["destination"]
      metadata["destination"] = destination.except("excerpts", "headings", "paragraphs", "opening") if destination
      metadata
    end
    private_class_method :compact_page
  end
end
