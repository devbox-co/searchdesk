module Tracking
  class ListingEvidence
    KEY = "site_organic_listings_v1"

    # The rank collector has already validated organic positions and their URLs.
    # Preserve the provider's exact wording, including its own truncation marks.
    def self.read(items:, host:, coverage:)
      items.filter_map do |item|
        next unless item["type"] == "organic"
        position = Integer(item["rank_group"].to_s, 10, exception: false)
        next unless position&.between?(1, coverage)
        url = eligible_url(item["url"], host)
        next unless url

        { "url" => item.fetch("url"), "position" => position, "title" => field(item["title"]),
          "description" => field(item["description"]), "pre_snippet" => field(item["pre_snippet"]),
          "breadcrumb" => field(item["breadcrumb"]), "website_name" => field(item["website_name"]) }
      end.sort_by { |row| row.fetch("position") }
    end

    def self.field(value)
      value if value.is_a?(String) && value.present? && value.bytesize <= 8192
    end
    private_class_method :field

    def self.eligible_url(value, host)
      url = ResultUrl.parse(value)
      url if url && ResultUrl.host_matches?(host, url.host) && url.port == url.default_port && !url.query && !url.fragment
    end

    def self.call(keyword:, device:, url:, provider: DataForSeo.new)
      new(keyword, device, url, provider).call
    end

    def initialize(keyword, device, url, provider)
      @keyword, @device, @url, @provider = keyword, device, url, provider
    end

    def call
      @series = @keyword&.tracking_series&.current&.find_by(device: @device, source: "dataforseo")
      return unavailable("No matching Google rank tracking is configured.") unless matching_scope?
      return unavailable("This page is outside the tracked website or uses an unsupported URL.") unless self.class.eligible_url(@url, @keyword.site.host)

      recent = @series.rank_observations.joins(:daily_slot).includes(:daily_slot)
        .where(source: "dataforseo", daily_slots: { day: (@series.date_in_zone - 55)..@series.date_in_zone })
        .order("daily_slots.day DESC").to_a
      latest = recent.shift
      return unavailable("There is no recent verified Google result for this search.") unless latest
      rows = listings(latest)
      return unavailable("The saved Google result could not be verified.") unless rows && latest.coverage.positive?
      target = rows.find { |row| same_url?(row["url"]) }
      facts = context(latest)
      return facts.merge(target, "status" => "observed") if target

      facts.merge!("status" => "target_not_seen", "other_result" => rows.first)
      # Older results are only read when the existing receipt records the target.
      older = recent.find { |reading| recorded_target?(reading) }
      if older
        previous = listings(older)&.find { |row| same_url?(row["url"]) }
        facts["previous_result"] = context(older).merge(previous, "status" => "observed") if previous
      end
      facts
    end

    private

    def matching_scope?
      return false unless @series
      site = @keyword.site
      settings = @series.settings
      settings.slice("host", "keyword", "country_code", "location", "location_code", "language", "device", "engine") ==
        { "host" => site.host.downcase, "keyword" => @keyword.phrase, "country_code" => site.rank_country_code,
          "location" => site.location, "location_code" => site.rank_location_code, "language" => site.language,
          "device" => @device, "engine" => "google" }
    end

    def same_url?(value)
      actual = ResultUrl.parse(value)
      target = ResultUrl.parse(@url)
      actual && actual.host.casecmp?(target.host) && ResultUrl.same_page?(@url, value)
    end

    def recorded_target?(reading)
      rows = reading.evidence[KEY] || reading.evidence[OrganicPageOverlap::KEY] || [
        { "url" => reading.winning_url, "position" => reading.position },
        { "url" => reading.preferred_url, "position" => reading.preferred_position }
      ]
      rows.any? { |row| row["position"].is_a?(Integer) && row["position"].between?(1, reading.coverage) && same_url?(row["url"]) }
    end

    def listings(reading)
      return unless reading.evidence["series_fingerprint"] == @series.fingerprint
      return reading.evidence[KEY] if reading.evidence.key?(KEY)

      # Re-read an existing task, never submit a new search. The provider checks
      # the task ID, query, location, language, device, OS, engine and slot tag.
      slot = reading.daily_slot
      return unless slot.task_id.present? && slot.task_id == reading.evidence["reference"]
      data = @provider.poll(slot)
      return unless data && data[:reference] == slot.task_id

      reading.with_lock do
        return reading.evidence[KEY] if reading.evidence.key?(KEY)
        captured_at = data.fetch(:captured_at).round(6)
        return unless reading.captured_at == captured_at && @series.date_in_zone(captured_at) == slot.day
        return unless reading.evidence["reference"] == data[:reference] && reading.evidence["series_fingerprint"] == @series.fingerprint
        attrs = RecordResult.observation_attributes(series: @series, day: slot.day, captured_at:, items: data.fetch(:items))
        return unless attrs.slice(:coverage, :position, :winning_url, :status).all? { |k, v| reading.public_send(k) == v }
        rows = attrs.fetch(:evidence).fetch(KEY)
        reading.update!(evidence: reading.evidence.merge(KEY => rows))
        rows
      end
    rescue DataForSeo::ScopeError, DataForSeo::Rejected, DataForSeo::Unavailable, RecordResult::Error
      nil
    end

    def context(reading)
      settings = @series.settings
      { "source" => "DataForSEO Google organic", "keyword" => @keyword.phrase, "target_url" => @url,
        "captured_at" => reading.captured_at.utc.iso8601, "location" => settings.fetch("location"),
        "location_code" => settings.fetch("location_code"), "country_code" => settings.fetch("country_code"),
        "language" => settings.fetch("language"), "device" => @device, "os" => settings.fetch("os"),
        "coverage" => reading.coverage, "depth" => settings.fetch("depth"), "observation_id" => reading.id,
        "result_domain" => reading.evidence["result_domain"] }
    end

    def unavailable(reason)
      { "status" => "unavailable", "reason" => reason, "target_url" => @url, "device" => @device }
    end
  end
end
