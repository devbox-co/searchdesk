module Semrush
  class CampaignDashboard
    METHOD = "semrush_position_tracking_feature_inclusive_v1"
    LEGACY_SCOPE = /\ASemrush Position Tracking\. (.+?), Google (desktop|mobile) in (English), ([a-z0-9.-]+)\. Local Pack and AI Overview positions are eligible\./i
    attr_reader :campaigns, :selected, :day, :cutoff, :rows

    def initialize(site:, requested_day: nil, campaign: nil)
      @site = site
      @today = Time.current.in_time_zone(site.time_zone).to_date
      tracked = site.keywords.select(Arel.sql("LOWER(phrase)"))
      records = site.source_snapshots.where(provider: "semrush").where("LOWER(keyword) IN (?)", tracked)
        .where("metrics ? 'latest_position' AND metrics ? 'latest_date'").order(:observed_on, :id)
      batches = records.filter_map { |record| read_record(record) }
      resolve_legacy_locations(batches)
      groups = batches.group_by { |batch| Digest::SHA256.hexdigest(JSON.generate(batch[:scope])) }
      @campaigns = groups.map do |id, entries|
        entries.first[:scope].merge(key: id, cutoff: entries.map { |entry| entry[:last][:date] }.max)
      end.sort_by { |scope| [-scope[:cutoff].jd, scope[:id], scope[:key]] }
      @selected = campaign.present? ? campaigns.find { |scope| scope[:key] == campaign } : campaigns.first
      @cutoff = selected&.fetch(:cutoff)
      @day = requested_day || cutoff || @today
      @rows = selected ? compare(groups.fetch(selected[:key])) : []
    end

    def available?
      campaigns.any?
    end

    private

    def read_record(record)
      data = record.metrics
      url = Tracking::ResultUrl.parse(record.source_url)
      return unless url.is_a?(URI::HTTPS) && url.port == 443 && %w[semrush.com www.semrush.com].include?(url.host)
      id = url.path[%r{\A/tracking/overview/(\d+_\d+)\.html/?\z}, 1]
      params = URI.decode_www_form(url.query.to_s).to_h
      host = params["domain_1"].to_s.downcase.delete_prefix("www.")
      return unless id && host.present? && Tracking::ResultUrl.host_matches?(@site.host, host)

      legacy = data["series_method"].nil?
      if legacy
        match = LEGACY_SCOPE.match(record.scope)
        return unless match && Tracking::ResultUrl.host_matches?(host, match[4])
        location, device, language, engine = match[1], match[2].downcase, "en", "google"
      else
        return unless data["series_method"] == METHOD && id == data["campaign_id"] && Tracking::ResultUrl.host_matches?(host, data["domain"])
        location, device, language, engine = data.values_at("location", "device", "language", "engine")
        return unless location.is_a?(String) && location.strip.present? && location.length <= 200 &&
          %w[mobile desktop tablet].include?(device) && language.to_s.match?(/\A[a-z]{2,3}(?:-[A-Za-z]{2,4})?\z/) && engine == "google"
      end
      scope = { id: id, host: host, location: location.squish, device: device, language: language, engine: engine, method: METHOD }
      last = observation(record, "latest")
      return unless last && last[:date] == record.observed_on && last[:date] <= @today
      first = observation(record, "previous")
      first = nil unless first && first[:date] < last[:date]
      { term: record.keyword, scope: scope, legacy: legacy, record: record, first: first, last: last }
    rescue ArgumentError
      nil
    end

    def resolve_legacy_locations(batches)
      # Older exports stored the market in prose. Accept its abbreviated name only when the
      # same campaign's structured export explicitly repeats it and identifies one full market.
      structured = batches.reject { |b| b[:legacy] }.group_by { |b| b[:scope].except(:location) }
      batches.select { |b| b[:legacy] }.each do |old|
        market = old[:scope][:location]
        candidates = structured.fetch(old[:scope].except(:location), []).filter_map do |newer|
          full = newer[:scope][:location]
          full if full == market || (full.start_with?("#{market}, ") && newer[:record].scope.include?(". #{market}, Google #{old[:scope][:device]}, English, "))
        end.uniq
        old[:scope][:location] = candidates.sole if candidates.one?
      end
    end

    def observation(record, tag)
      data = record.metrics
      return unless data.key?("#{tag}_position")
      date = Date.iso8601(data["#{tag}_date"].to_s)
      raw = data["#{tag}_position"]
      rank = Integer(raw.to_s, 10, exception: false)
      return unless raw.nil? || rank&.positive?
      url = Tracking::ResultUrl.parse(data["#{tag}_reported_url"])
      page = url.to_s if rank && url && Tracking::ResultUrl.host_matches?(@site.host, url.host)
      badge = data["#{tag}_feature"]
      { date: date, rank: rank, feature: (badge.strip.first(80).presence if rank && badge.is_a?(String)), page: page, record: record }
    rescue Date::Error
      nil
    end

    def compare(batches)
      batches.group_by { |b| b[:term].downcase }.map do |_, entries|
        readings = {}
        # The date's own capture has precedence over a later recap that can omit page or feature details.
        entries.each { |b| readings[b[:first][:date]] = b[:first] if b[:first] }
        entries.each { |b| readings[b[:last][:date]] = b[:last] }
        prior = readings.values.select { |reading| reading[:date] <= day }
        first = prior.min_by { |reading| reading[:date] }
        baseline = prior.select { |reading| reading[:rank] }.min_by { |reading| reading[:date] } || first
        current = readings[day]
        change = baseline[:rank] - current[:rank] if baseline&.dig(:rank) && current&.dig(:rank) && baseline[:date] < day
        { term: entries.first[:term], first: first, baseline: baseline, current: current, latest: prior.max_by { |reading| reading[:date] }, change: change }
      end.sort_by { |row| row[:term].downcase }
    end
  end
end
