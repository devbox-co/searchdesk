module CompetingPages
  # An imported public page capture can describe a retired URL when its current
  # HTTP response is a redirect. Only compare a copy dated on or before the SERP.
  class ArticleArchive
    PROVIDER = "Website page archive"
    FORMAT = "public_page_v1"

    def self.call(site:, google:, page:)
      results_at = Time.iso8601(google.fetch("captured_at"))
      rows = site.source_snapshots.where(provider: PROVIDER, source_url: google.fetch("url"), observed_on: ..results_at.to_date)
        .where("metrics->>'format' = ?", FORMAT).order(observed_on: :desc, id: :desc)
      candidates = rows.filter_map do |row|
        data = row.metrics
        captured = timestamp(data["captured_at"])
        if captured && captured <= results_at && captured.to_date == row.observed_on &&
            data["http_status"] == 200 && data["final_url"] == row.source_url
          [captured, row]
        end
      end
      captured, row = candidates.max_by(&:first)
      return unless row
      data = row.metrics
      snapshot = data.slice("title", "description", "captured_at").merge("status" => "observed")
      needle = google["description"].to_s.squish
      needle = ArticleComparison.visible_prefix(needle) || needle
      body = data["article_text"].to_s.squish
      matched = needle.length >= 24 && body.include?(needle)
      snapshot.merge("url" => row.source_url, "snapshot_id" => row.id,
        "comparison" => ArticleComparison.fields(google, snapshot), "snippet_in_body" => matched, "matched_passage" => (needle if matched),
        "prior_redirect" => prior_redirect(data, page, captured, results_at))
    end

    def self.prior_redirect(data, page, captured, results_at)
      hop = data["prior_redirect"]
      return unless hop.is_a?(Hash) && page["status"] == "redirected"
      observed = timestamp(hop["captured_at"])
      current = Array(page["redirects"]).first
      return unless observed && observed.between?(captured, results_at) && current &&
        [301, 308].include?(hop["status"]) && hop["status"] == current["status"] && hop["location"] == current["location"]
      hop.slice("captured_at", "status", "location")
    end

    def self.timestamp(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
    private_class_method :prior_redirect, :timestamp
  end
end
