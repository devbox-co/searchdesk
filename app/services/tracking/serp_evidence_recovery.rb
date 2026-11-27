module Tracking
  module SerpEvidenceRecovery
    FEATURES = { "P2" => GoogleLocalPack::KEY, "M4" => GoogleLocalServices::KEY }.freeze

    def self.available_series(site, feature:, now: Time.current)
      return [] unless FEATURES.key?(feature) && site.tracking_mode == "dataforseo" && DataForSeo.enabled?
      return [] if feature == "M4" && !GooglePlacement.profile_for(site)

      ids = scope(site, feature, now).select("tracking_series.id")
      TrackingSeries.current.where(id: ids).includes(:keyword).order(:keyword_id, :device).limit(100)
        .select { |series| DataForSeo.series_allowed?(series.id) }
    end

    def self.call(site:, series_id:, owner_id:, feature:, now: Time.current)
      return [] unless site.workspace.memberships.exists?(user_id: owner_id, role: "owner")

      series = available_series(site, feature: feature, now: now).find { |candidate| candidate.id.to_s == series_id.to_s }
      return [] unless series

      profile = GooglePlacement.profile_for(site) if feature == "M4"
      period_method = feature == "M4" ? :beginning_of_week : :beginning_of_month
      scope(site, feature, now).where(tracking_series: { id: series.id }).order("daily_slots.day DESC", id: :desc)
        .group_by { |observation| observation.day.public_send(period_method) }.values.filter_map do |observations|
          recover(observations.first, site, FEATURES.fetch(feature), profile)
        end
    end

    def self.scope(site, feature, now)
      today = now.in_time_zone(site.time_zone).to_date
      start = feature == "M4" ? today.beginning_of_week - 7 : today.beginning_of_month.prev_month
      RankObservation.provider_for(site).merge(TrackingSeries.current).where(daily_slots: { day: start..today })
        .where("daily_slots.attempted_at > ? AND daily_slots.task_id = rank_observations.evidence->>'reference'", now - 30.days)
        .where("tracking_series.fingerprint = rank_observations.evidence->>'series_fingerprint'")
    end

    def self.recover(observation, site, key, profile)
      return if captured?(observation, key, profile)

      slot = observation.daily_slot
      reference = slot.task_id
      capture = DataForSeo.new.poll(slot)
      return unless capture && capture.fetch(:reference) == reference &&
        capture.fetch(:captured_at).round(6) == observation.captured_at

      items = capture.fetch(:items)
      return unless items.is_a?(Array) && items.size <= 500 && items.all?(Hash)

      sample = key == GoogleLocalServices::KEY ? GoogleLocalServices.read(items, profile: profile) : GoogleLocalPack.read(items)
      return unless sample

      observation.with_lock do
        next if captured?(observation, key, profile) || observation.captured_at != capture.fetch(:captured_at).round(6) ||
          observation.evidence["reference"] != reference || slot.reload.task_id != reference
        series = slot.tracking_series.reload
        current_site = series.site.reload
        next if current_site.host != site.host || series.archived_at.present?
        next if profile && GooglePlacement.profile_for(current_site)&.place_id != profile.place_id

        observation.update!(evidence: observation.evidence.merge(key => sample))
        observation
      end
    rescue DataForSeo::Unavailable, DataForSeo::Rejected, DataForSeo::ScopeError
      nil
    end

    def self.captured?(observation, key, profile)
      return observation.evidence.key?(key) unless profile

      observation.evidence.dig(key, "place_id") == profile.place_id
    end

    private_class_method :scope, :recover, :captured?
  end
end
