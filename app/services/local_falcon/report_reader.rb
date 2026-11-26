module LocalFalcon
  class ReportReader
    REPORT_KEY = /\A[a-f0-9]{15}\z/
    SCAN_MASK = "report_key,date,place_id,keyword,platform,grid_size,radius,measurement,arp,atrp,solv,found_in"
    CAMPAIGN_MASK = "report_key,name,status,locations,keywords,frequency,last_run,next_run"
    METRICS = %w[WEBSITE_CLICKS CALL_CLICKS BUSINESS_DIRECTION_REQUESTS BUSINESS_IMPRESSIONS_DESKTOP_MAPS BUSINESS_IMPRESSIONS_MOBILE_MAPS BUSINESS_IMPRESSIONS_DESKTOP_SEARCH BUSINESS_IMPRESSIONS_MOBILE_SEARCH].freeze

    def self.saved_key(site)
      link = site.site_report_links.find_by(provider: "local-falcon")
      key = URI(link.url).path.split("/").last if link&.valid?
      key if key&.match?(REPORT_KEY)
    end

    def initialize(client, site, place_id)
      @client, @site, @place = client, site, place_id
      @today = Time.current.in_time_zone(site.time_zone).to_date
    end

    def read
      if @place.blank?
        key = self.class.saved_key(@site)
        raise Client::Error, "Save a valid Local Falcon scan link or Google Place ID first." unless key
        report = @client.read("getLocalFalconReport", {reportKey: key, fieldmask: "report_key,place_id,platform"})
        raise Client::Error, "The saved link is not a Google Maps scan from this account." unless report["report_key"] == key && report["platform"] == "google"
        @place = report["place_id"]
      end
      raise Client::Error, "The scan did not supply a valid Google Place ID." unless @place.is_a?(String) && @place.match?(/\A[A-Za-z0-9_-]{12,180}\z/)
      locations = @client.read("listAllLocalFalconLocations", {query: @place}).fetch("locations")
      location = locations.find { |l| l["place_id"] == @place && l["platform"] == "google" } if locations.is_a?(Array)
      website = Tracking::ResultUrl.parse(location&.dig("url"))
      unless website && Tracking::ResultUrl.host_matches?(@site.host, website.host)
        raise Client::Error, "This Local Falcon listing’s verified website does not match this site. Check the Place ID and connected account."
      end
      scans = pages("listLocalFalconScanReports", {placeId: @place, platform: "google", fieldmask: SCAN_MASK,
        startDate: (@today - 31).strftime("%m/%d/%Y"), endDate: @today.strftime("%m/%d/%Y")}).filter_map { |row| scan(row) }
      grids = read_grids(scans)
      campaigns = pages("listLocalFalconCampaignReports", {placeId: @place, fieldmask: CAMPAIGN_MASK}).filter_map { |row| campaign(row) }
      gbp = nil
      if location["gbp_linked"] == true || location["gbp_linked"] == "1"
        begin
          gbp = engagement
          gbp_label = "Business Profile metrics through #{gbp.dig(:metrics, :end)}"
        rescue Client::ToolError
          gbp_label = "Business Profile metrics unavailable from this grant"
        end
      else
        gbp_label = "Business Profile is not linked"
      end
      { place_id: @place, verified_name: location.fetch("name"), rows: scans + campaigns + Array.wrap(gbp), grids: grids,
        result: {"scans" => scans.size, "campaigns" => campaigns.size,
          "campaign_snapshot_ids" => campaigns.pluck(:external_id), "gbp" => gbp_label,
          "google_cid" => google_cid(location)}.compact }
    rescue KeyError, TypeError, ArgumentError, NoMethodError
      raise Client::Error, "Local Falcon returned an incomplete or invalid report. Previous evidence is retained."
    end

    private

    def google_cid(location)
      cid = location["cid"].to_s
      return cid if cid.match?(/\A[1-9]\d{0,19}\z/) && cid.to_i <= (2**64 - 1)

      url = Tracking::ResultUrl.parse(location["map_link"])
      return unless url&.scheme == "https" && url.host == "www.google.com" && url.path.start_with?("/maps/")
      hex = url.path[%r{!1s0x[0-9a-fA-F]{1,16}:0x([0-9a-fA-F]{1,16})(?:!|\z)}, 1]
      value = hex&.to_i(16)
      value.to_s if value&.positive?
    end

    def pages(tool, args)
      data = []
      seen = Set.new
      10.times do
        result = @client.read(tool, args)
        rows = result.fetch("reports")
        raise Client::Error, "Local Falcon returned invalid report rows." unless rows.is_a?(Array) && rows.all?(Hash)
        data.concat(rows)
        token = result["next_token"]
        return data if token.blank?
        raise Client::Error, "Local Falcon returned an invalid pagination token." unless token.is_a?(String) && seen.add?(token)
        args = args.merge(nextToken: token)
      end
      raise Client::Error, "This reporting window exceeded the refresh limit."
    end

    def read_grids(scans)
      keys = scans.map { |row| row[:external_id] }
      saved = @site.source_snapshots.where(provider: "Local Falcon", external_id: keys)
        .where("map_grid->>'place_id' = ?", @place).pluck(:external_id).to_set
      pending = scans.reject { |row| saved.include?(row[:external_id]) }
        .sort_by { |row| row[:observed_on] }.reverse.first(8)
      pending.each_with_object({}) do |row, grids|
        report = @client.read("getLocalFalconReport", {reportKey: row[:external_id], fieldmask: ScanGrid::FIELD_MASK})
        grid = ScanGrid.from_report(report, row, @place)
        grids[row[:external_id]] = grid if grid
      rescue Client::ToolError
        # Summary-only scans remain usable while the provider has no pin details.
        next
      end
    end

    def scan(row)
      return unless row["place_id"] == @place && row["platform"] == "google"
      key = row.fetch("report_key")
      raise ArgumentError unless REPORT_KEY.match?(key)
      date = Date.strptime(row.fetch("date").split.first, "%m/%d/%Y")
      return unless ((@today - 31)..@today).cover?(date)
      term = row.fetch("keyword").to_s.strip
      raise ArgumentError unless term.length.between?(1,200)
      # A scan can legitimately have no observed average. Pinned detail is bound separately.
      grid = Integer(row.fetch("grid_size"))
      raise ArgumentError unless grid.between?(1,21)
      metrics = {place_id: @place, grid_size: grid, radius: Float(row.fetch("radius")), distance_unit: row.fetch("measurement")}
      %w[arp atrp solv found_in].each do |field|
        next unless row[field].present? && row[field] != "-"
        n = Float(row[field])
        raise ArgumentError unless n.finite? && n >= 0
        metrics[field] = field == "found_in" ? Integer(row[field]) : n
      end
      {provider: "Local Falcon", external_id: key, title: "#{term} · Maps scan", observed_on: date, keyword: term,
        scope: "Existing Google Maps scan for #{@site.host}. Local Falcon grid summary for one place. Dates follow the provider’s report.",
        metrics: metrics, source_url: "https://app.localfalcon.com/reports/view/#{key}"}
    end

    def campaign(row)
      # The vendor's placeId filter selects matching campaigns. Omit all multi-location records to prevent cross-site disclosure.
      return unless Integer(row.fetch("locations")) == 1
      key = row.fetch("report_key")
      raise ArgumentError unless REPORT_KEY.match?(key)
      facts = { place_id: @place, locations: 1, keywords: Integer(row.fetch("keywords")), frequency: row["frequency"], status: row["status"] }
      %w[last_run next_run].each do |k|
        facts[k] = Time.at(Integer(row[k])).utc.iso8601 if row[k].present?
      end
      {provider: "Local Falcon", external_id: "campaign-#{key}-#{@today}", title: "Maps campaign · #{row.fetch('name')}".truncate(255),
        observed_on: @today, scope: "Single-location campaign returned by the verified place filter. Times are UTC. Scheduled times describe the provider campaign.", metrics: facts,
        source_url: "https://app.localfalcon.com/campaigns/"}
    end

    def engagement
      last = @today - 4
      first = last - 27
      args = {placeId: @place, startDate: first.iso8601, endDate: last.iso8601, metrics: METRICS.join(",")}
      report = @client.read("getLocalFalconGbpPerformanceMetrics", args)
      raise Client::Error, "Local Falcon returned a different Business Profile or date range." unless report["place_id"] == @place && report["start_date"] == args[:startDate] && report["end_date"] == args[:endDate]
      result = report.fetch("totals")
      counts = METRICS.to_h { |k| [k, Integer(result.fetch(k))] }
      raise ArgumentError if counts.values.any?(&:negative?)
      {provider: "Google Business Profile", external_id: SourceSnapshot::GBP_CACHE_ID, title: "Business Profile interactions · 28 days through #{last}",
        observed_on: @today, scope: "One linked profile, reported through Local Falcon. The latest four days are excluded for processing lag. Google may revise counts. These are interactions across the profile’s searches.",
        metrics: {place_id: @place, start: first.iso8601, end: last.iso8601, totals: counts}, source_url: "https://business.google.com/"}
    end
  end
end
