module SearchConsole
  class SitemapSummary
    def self.fetch(client:, token:, property:)
      checked = Time.current.utc.iso8601
      rows = client.sitemaps(token: token, property: property)
      raise ArgumentError unless rows.is_a?(Array)
      totals = { "count" => rows.length, "errors" => 0, "warnings" => 0, "pending" => 0 }
      downloads = rows.filter_map do |row|
        raise ArgumentError unless row.is_a?(Hash) && row["path"].is_a?(String) && row["path"].present?
        %w[errors warnings].each do |key|
          count = row.fetch(key, 0).to_s
          raise ArgumentError unless count.match?(/\A[0-9]{1,18}\z/)
          totals[key] += Integer(count, 10)
        end
        pending = row.fetch("isPending", false)
        raise ArgumentError unless [true, false].include?(pending)
        totals["pending"] += 1 if pending
        Time.iso8601(row["lastDownloaded"]).utc if row["lastDownloaded"].present?
      end
      totals.merge("status" => "available", "checked_at" => checked, "last_downloaded" => downloads.max&.iso8601)
    rescue Client::Error, ArgumentError, TypeError
      # Sitemap reporting is independent of Search Analytics, which can already have succeeded.
      { "status" => "unavailable", "checked_at" => checked }
    end
  end
end
