module Tracking
  class PlacementBackfill
    def self.call(site:, from:, through:, keyword: nil, provider: DataForSeo.new)
      today = Time.current.in_time_zone(site.time_zone).to_date
      unless from <= through && from >= today - 29 && through <= today
        raise ArgumentError, "Choose dates within the last 30 days"
      end

      profile = GooglePlacement.profile_for(site)
      verified_from = if profile
        scans = LocalFalcon::MapsSummary.scan_scope(site)
          .where("COALESCE(metrics->>'place_id', map_grid->>'place_id') = ?", profile.place_id)
        [scans.minimum(:observed_on), site.local_falcon_connection.synced_at.in_time_zone(site.time_zone).to_date].compact.min
      end
      series = TrackingSeries.joins(:keyword).where(keywords: {site_id: site.id}, source: "dataforseo")
      series = series.where(keywords: {phrase: keyword}) if keyword
      observations = RankObservation.comparable.joins(:daily_slot)
        .where(source: "dataforseo", daily_slots: {tracking_series_id: series.select(:id), day: from..through})
        .where.not(daily_slots: {task_id: nil})
        .where("NOT (evidence ? :key)", key: GooglePlacement::KEY)
        .includes(daily_slot: :tracking_series)

      counts = Hash.new(0)
      observations.find_each do |observation|
        result = if verified_from && observation.day < verified_from
          :unverified_profile
        else
          restore(observation, profile, provider)
        end
        counts[result] += 1
      end
      counts
    end

    def self.restore(observation, profile, provider)
      slot = observation.daily_slot
      return :unmatched unless observation.evidence["reference"] == slot.task_id

      data = provider.poll(slot)
      return :unavailable unless data
      return :unmatched unless data.fetch(:reference) == slot.task_id &&
        data.fetch(:captured_at).round(6) == observation.captured_at

      series = slot.tracking_series
      organic = RecordResult.observation_attributes(series:, captured_at: observation.captured_at, day: slot.day, items: data.fetch(:items))
      return :unmatched unless %i[coverage status position winning_url].all? { |key| organic[key] == observation.public_send(key) }

      placement = GooglePlacement.read(items: data.fetch(:items), organic:, depth: series.settings.fetch("depth"), profile:)
      return :unavailable unless placement

      observation.with_lock do
        next :already_saved if observation.evidence.key?(GooglePlacement::KEY)

        observation.update!(evidence: observation.evidence.merge(GooglePlacement::KEY => placement))
        :saved
      end
    rescue DataForSeo::Unavailable, DataForSeo::Rejected
      :unavailable
    rescue DataForSeo::ScopeError, RecordResult::Error
      :unmatched
    end
    private_class_method :restore
  end
end
