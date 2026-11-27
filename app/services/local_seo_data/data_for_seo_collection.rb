module LocalSeoData
  module DataForSeoCollection
    PROVIDER = "DataForSEO"

    def self.bound?(site, task)
      ENV["DATAFORSEO_#{task}_SITE_ID"] == site.id.to_s && ENV["DATAFORSEO_#{task}_SITE_HOST"] == site.host
    end

    def self.enabled?(site, task)
      bound?(site, task) && Tracking::DataForSeo.enabled? && settings(task).present?
    end

    def self.settings(task)
      place_id = ENV["DATAFORSEO_#{task}_PLACE_ID"].to_s.strip
      location_code = Integer(ENV["DATAFORSEO_#{task}_LOCATION_CODE"].to_s, 10, exception: false)
      return unless place_id.match?(/\A[A-Za-z0-9_-]{10,160}\z/) && location_code&.between?(1, 2_147_483_647)

      { place_id: place_id, location_code: location_code }
    end

    def self.reserve(site, template, day, metrics)
      SourceSnapshot.transaction do
        Tracking::DataForSeoBudget.lock!
        existing = Collection.receipt(site, template.key, day)
        next [existing, false] if existing

        now = Time.current
        next [nil, false] if Tracking::DataForSeoBudget.daily_full?(now) || Tracking::DataForSeoBudget.rolling_full?(now)

        snapshot = site.source_snapshots.create!(provider: PROVIDER, external_id: "#{template.key}-#{day}",
          title: "#{template.name} · provider collection", observed_on: now.in_time_zone(site.time_zone).to_date,
          scope: "DataForSEO sample for #{site.host} and the reporting period ending #{day}.", metrics: metrics)
        [snapshot, true]
      end
    end
  end
end
