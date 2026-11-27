module Tracking
  class OrganicPageOverlap
    KEY = "site_organic_pages"

    def self.for(keyword:, device:, urls:)
      return unless keyword && urls.is_a?(Array) && urls.uniq.size == 2
      series = keyword.tracking_series.current.find_by(device: device, source: "dataforseo")
      return unless series && series.settings["host"] == keyword.site.host.downcase

      recent = series.rank_observations.joins(:daily_slot).includes(:daily_slot)
        .where(source: "dataforseo", daily_slots: { day: (series.date_in_zone - 55)..series.date_in_zone })
        .order("daily_slots.day DESC")
      recent.each do |reading|
        # Older receipts retained both positions when the chosen page also appeared.
        pages = reading.evidence[KEY] || [
          { "url" => reading.winning_url, "position" => reading.position },
          { "url" => reading.preferred_url, "position" => reading.preferred_position }
        ]
        pair = urls.map do |url|
          pages.find { |p| p["url"] == url && p["position"].is_a?(Integer) && p["position"].between?(1, reading.coverage) }
        end
        next if pair.any?(&:nil?)
        return { day: reading.day, location: series.settings.fetch("location"), device: series.device,
          pages: pair.map { |p| { url: p.fetch("url"), position: p.fetch("position") } } }
      end
      nil
    end
  end
end
