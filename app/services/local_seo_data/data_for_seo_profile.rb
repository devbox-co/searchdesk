module LocalSeoData
  module DataForSeoProfile
    WEEKDAYS = %w[monday tuesday wednesday thursday friday saturday sunday].freeze

    def self.settings = DataForSeoCollection.settings("M3")

    def self.collect(site, template, day)
      input = settings
      metrics = { "kind" => "gbp_monitor", "host" => site.host, "period_on" => day.iso8601,
        "scope_digest" => Digest::SHA256.hexdigest([site.host, input, "en"].to_json),
        "state" => "collecting", "sandbox" => false }
      snapshot, reserved = DataForSeoCollection.reserve(site, template, day, metrics)
      return unless snapshot
      unless reserved
        return :pending if snapshot.metrics["state"] == "collecting" && snapshot.updated_at > 10.minutes.ago

        return
      end

      item = Tracking::DataForSeo.new.business_profile(**input)
      summary = BusinessProfile.summary(profile(item), place_id: input.fetch(:place_id), site: site)
      snapshot.update!(metrics: metrics.merge(summary).merge("state" => "captured"))
      nil
    rescue Tracking::DataForSeo::Unavailable, Client::Unavailable
      snapshot.update!(metrics: metrics.merge("state" => "unconfirmed"))
      nil
    end

    def self.profile(item)
      data = { "matched" => true, "place_id" => item.fetch("place_id") }
      { "title" => "name", "address" => "address", "phone" => "phone", "url" => "website" }.each do |key, field|
        data[field] = item[key] if item[key].is_a?(String)
      end
      if item["category"].present? && (item["additional_categories"].nil? || item["additional_categories"].is_a?(Array))
        data["categories"] = [item["category"], *item["additional_categories"]]
      end
      work_time = item["work_time"]
      work_hours = work_time["work_hours"] if work_time.is_a?(Hash)
      hours = normalize_hours(work_hours["timetable"]) if work_hours.is_a?(Hash)
      data["hours"] = hours if hours.present?
      data
    end

    def self.normalize_hours(timetable)
      return unless timetable.is_a?(Hash) && WEEKDAYS.all? { |day| timetable.key?(day) }

      WEEKDAYS.to_h do |day|
        windows = timetable[day]
        return unless windows.nil? || (windows.is_a?(Array) && windows.size <= 10)

        periods = Array(windows).map do |window|
          return unless window.is_a?(Hash)

          open_at = clock_time(window["open"])
          close_at = clock_time(window["close"])
          return unless open_at && close_at

          "#{open_at}-#{close_at}"
        end
        [day, periods.uniq.sort.join(", ")]
      end
    end

    def self.clock_time(value)
      return unless value.is_a?(Hash) && (0..24).cover?(value["hour"]) && value["hour"].is_a?(Integer) &&
        (0..59).cover?(value["minute"]) && value["minute"].is_a?(Integer)
      return if value["hour"] == 24 && value["minute"] != 0

      format("%02d:%02d", value["hour"], value["minute"])
    end

    private_class_method :profile, :normalize_hours, :clock_time
  end
end
