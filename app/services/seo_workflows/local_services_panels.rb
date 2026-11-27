module SeoWorkflows
  class LocalServicesPanels
    include Rails.application.routes.url_helpers

    KEY = Tracking::GoogleLocalServices::KEY

    def self.scope(site)
      observations = RankObservation.provider_for(site)
      profile = Tracking::GooglePlacement.profile_for(site)
      return observations.none unless profile

      observations.where("rank_observations.evidence->CAST(? AS text)->>'place_id' = ?", KEY, profile.place_id)
    end

    def initialize(site, start, day)
      @site, @start, @day = site, start, day
    end

    def rows
      captures = latest(@start..@day).limit(20)
      series_ids = captures.map(&:panel_series_id)
      return [] if series_ids.empty?

      previous = latest((@start - 7)...@start).where(tracking_series: { id: series_ids }).index_by(&:panel_series_id)
      captures.map do |capture|
        sample = capture.evidence.fetch(KEY)
        description = Tracking::GoogleLocalServices.description(sample)
        text = "#{capture.panel_keyword} · #{capture.panel_market} · #{capture.panel_device} · #{capture.panel_day}. #{description}"
        baseline = previous[capture.panel_series_id]
        old_position = baseline&.evidence&.dig(KEY, "panel_position")
        position = sample["panel_position"]
        output = { "source" => "DataForSEO Local Services panel", "path" => local_services_capture_seo_workflows_path(capture_id: capture.id) }
        if position && old_position
          text += " Previous sample on #{baseline.panel_day}: position #{old_position}."
          if old_position <= 3 && position > 3
            text += " The listing moved outside the first three positions."
            output["attention"] = true
          elsif position - old_position >= 3
            text += " The listing dropped #{position - old_position} positions."
            output["attention"] = true
          end
          output["baseline_path"] = local_services_capture_seo_workflows_path(capture_id: baseline.id)
        end
        output.merge("text" => text)
      end
    end

    private

    def latest(range)
      self.class.scope(@site).merge(TrackingSeries.current).where(daily_slots: { day: range })
        .select(Arel.sql(<<~SQL.squish))
          DISTINCT ON (tracking_series.id) rank_observations.*,
          tracking_series.id AS panel_series_id, daily_slots.day AS panel_day,
          tracking_series.device AS panel_device, tracking_series.settings->>'location' AS panel_market,
          keywords.phrase AS panel_keyword
        SQL
        .order("tracking_series.id", "daily_slots.day DESC")
    end
  end
end
