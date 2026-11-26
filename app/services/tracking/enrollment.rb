require "digest"

module Tracking
  class Enrollment
    def self.call(site:, phrase:, preferred_url: nil, devices: %w[mobile desktop])
      phrase = phrase.to_s.strip
      devices = Array(devices).map(&:to_s).uniq
      raise ArgumentError, "Select mobile or desktop" if devices.empty? || (devices - %w[mobile desktop]).any?
      site.with_lock do
        if site.tracking_mode == "dataforseo" && !(site.rank_location_verified_at && site.rank_location_name == site.location && site.rank_location_code.to_i.positive?)
          raise ArgumentError, "Verify the provider town and country before tracking these keywords."
        end
        keyword = site.keywords.find_or_initialize_by(phrase: phrase)
        if preferred_url.present?
          url = ResultUrl.parse(preferred_url)
          raise ArgumentError, "Use an HTTP or HTTPS URL on this website" unless url && ResultUrl.host_matches?(site.host, url.host)
          keyword.preferred_url = preferred_url
        end
        keyword.save!
        devices.each do |device|
          settings = { "host" => site.host.downcase, "keyword" => phrase, "location" => site.location,
                       "location_code" => site.rank_location_code, "country_code" => site.rank_country_code, "language" => site.language, "device" => device,
                       "os" => (device == "mobile" ? "android" : "windows"), "engine" => "google",
                       "depth" => 30, "source" => site.tracking_mode, "time_zone" => site.time_zone,
                       "method" => "organic_group_v1", "host_policy" => "exact_www_alias" }
          fingerprint = Digest::SHA256.hexdigest(JSON.generate(settings.sort))
          current = keyword.tracking_series.current.find_by(device: device)
          next if current&.fingerprint == fingerprint
          current&.update!(archived_at: Time.current)
          today = Time.current.in_time_zone(site.time_zone).to_date
          series = keyword.tracking_series.create!(device: device, source: site.tracking_mode,
            settings: settings, fingerprint: fingerprint, enrolled_on: site.tracking_mode == "demo" ? today - 6 : today)
          if series.source == "demo"
            DemoHistory.fill(series, from: series.enrolled_on, through: today)
          else
            series.daily_slots.create!(day: today)
          end
        end
        keyword
      end
    end
  end
end
