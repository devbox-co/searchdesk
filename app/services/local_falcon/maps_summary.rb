module LocalFalcon
  class MapsSummary
    attr_reader :snapshot

    def self.scan_scope(site)
      SourceSnapshot.visible_for(site).where(provider: "Local Falcon").where.not(keyword: [nil, ""])
        .where("external_id ~ '^[0-9a-f]{15}$' AND metrics ? 'grid_size'")
        .where("metrics->>'platform' = 'google' OR (metrics->>'platform' IS NULL AND scope ILIKE '%Google Maps%')")
    end

    def self.verified_scan_scope(site)
      profile = Tracking::GooglePlacement.profile_for(site)
      return scan_scope(site).none unless profile

      scans = scan_scope(site)
      live = scans.where("metrics->>'place_id' = ?", profile.place_id)
        .where("scope LIKE ?", "Existing Google Maps scan for #{SourceSnapshot.sanitize_sql_like(site.host)}.%")
      # Older archived reports stored their verified place on the pin grid. Keep the
      # exact place and report identity checks when reading those saved records.
      archived = scans.where.not(source_path: [nil, ""]).where(<<~SQL.squish, profile.place_id)
        metrics->>'place_id' IS NULL AND map_grid->>'place_id' = ?
        AND source_url = 'https://app.localfalcon.com/reports/view/' || external_id
        AND map_grid->>'report_key' = external_id
        AND lower(map_grid->>'keyword') = lower(keyword)
        AND map_grid->>'date' = observed_on::text
        AND map_grid->>'grid_size' = metrics->>'grid_size'
        AND jsonb_typeof(map_grid->'points') = 'array'
        AND map_grid->'points' <> '[]'::jsonb
      SQL
      live.or(archived)
    end

    def self.latest(site, through: nil, keywords: [])
      scans = scan_scope(site)
      scans = scans.where(observed_on: ..through) if through
      scans = scans.where("LOWER(keyword) IN (?)", keywords.map(&:downcase)) if keywords.any?
      # Keep the latest observation for each exact keyword before limiting the number shown.
      by_term = scans.select("DISTINCT ON (LOWER(keyword)) source_snapshots.*")
        .order(Arel.sql("LOWER(keyword), observed_on DESC, id DESC"))
      SourceSnapshot.from(by_term, :source_snapshots).order(observed_on: :desc, keyword: :asc).limit(5).map { |scan| new(scan) }
    end

    def initialize(snapshot)
      @snapshot = snapshot
      @metrics = snapshot.metrics
    end

    def report_url
      "https://app.localfalcon.com/reports/view/#{snapshot.external_id}"
    end

    def grid_size
      integer(@metrics["grid_size"], 1..21)
    end

    def radius
      distance = Float(@metrics["radius_miles"] || @metrics["radius"], exception: false)
      unit = @metrics.key?("radius_miles") ? "mi" : @metrics["distance_unit"]
      [distance, unit] if distance&.finite? && distance.positive? && %w[mi km].include?(unit)
    end

    def average_rank
      position = Float(@metrics["arp"], exception: false)
      position if position&.finite? && position >= 1
    end

    def share
      percent = Float(@metrics["share_of_local_voice_pct"] || @metrics["solv"], exception: false)
      percent if percent&.finite? && percent.between?(0,100)
    end

    def top_three_counts
      total = integer(@metrics["grid_pins"], 1..441)
      return unless total
      top = integer(@metrics["top_three_pins"], 0..total)
      [top, total] if top
    end

    def comparisons
      %w[compared_with_previous compared_with_first].filter_map do |key|
        pair = @metrics[key]
        next unless pair.is_a?(Hash)
        date = Date.iso8601(pair["earlier_date"].to_s)
        pins = integer(pair["matched_pins"], 1..441)
        next unless date < snapshot.observed_on && pins
        gained = integer(pair["gained_top_three"], 0..pins)
        lost = integer(pair["lost_top_three"], 0..pins)
        { date: date, pins: pins, gained: gained, lost: lost } if gained && lost && gained + lost <= pins
      rescue Date::Error
        nil
      end.uniq { |pair| pair[:date] }
    end

    private

    def integer(value, range)
      n = Integer(value.to_s, 10, exception: false)
      n if n && range.cover?(n)
    end
  end
end
