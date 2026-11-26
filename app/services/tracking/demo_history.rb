module Tracking
  class DemoHistory
    FOLLOW_UP_OFFSETS = [0, 1, -1, 0, 2, 1, -2, 0].freeze

    def self.call(site:, days: 7)
      raise ArgumentError, "Demo data requires an explicitly selected demo site" unless site.tracking_mode == "demo"
      TrackingSeries.current.joins(:keyword).where(keywords: { site_id: site.id }, source: "demo", paused: false).find_each do |series|
        today = series.date_in_zone
        fill(series, from: [today - days.clamp(1, 30) + 1, series.enrolled_on].max, through: today)
      end
    end

    def self.fill(series, from:, through:)
      raise ArgumentError, "Simulated observations require a demo series" unless series.source == "demo"
      service = series.keyword.phrase.downcase.delete_suffix(" #{series.settings.fetch('location').downcase}")
      seed = series.fingerprint[0, 8].to_i(16)
      example = DemoSiteSetup::EXAMPLES.fetch(service) { DemoSiteSetup::EXAMPLES.values[seed % DemoSiteSetup::EXAMPLES.size] }
      zone = ActiveSupport::TimeZone[series.settings.fetch("time_zone")]
      (from..through).each do |day|
        next if series.rank_observations.joins(:daily_slot).exists?(daily_slots: { day: day })
        capture = [zone.local(day.year, day.month, day.day, 8), Time.current.change(usec: 0)].min
        day_index = (day - series.enrolled_on).to_i
        position = sample_position(example.fetch(:first_week), day_index, series.device, seed)
        homepage = "https://#{series.settings.fetch('host')}/"
        destination = series.keyword.preferred_url.presence || homepage
        destination = homepage if example[:homepage_from_day] && day_index >= example[:homepage_from_day]
        items = (1..30).map do |rank|
          { "type" => "organic", "rank_group" => rank, "url" => rank == position ? destination : "https://result-#{rank}.invalid/" }
        end
        RecordResult.call(series: series, captured_at: capture, expected_day: day, items: items,
                          metadata: { "source_label" => "Simulated demonstration" })
      end
    end

    def self.sample_position(first_week, day_index, device, seed)
      if day_index < first_week.size
        value = first_week.fetch(day_index)
        return unless value
      else
        phase = (day_index - first_week.size + seed) % FOLLOW_UP_OFFSETS.size
        value = first_week.last + FOLLOW_UP_OFFSETS[phase]
      end
      (device == "desktop" ? value + 2 : value).clamp(1, 30)
    end
    private_class_method :sample_position
  end
end
