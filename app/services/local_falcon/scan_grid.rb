module LocalFalcon
  class ScanGrid
    FIELD_MASK = "report_key,place_id,date,platform,keyword,grid_size,radius,measurement,image,data_points.*.lat,data_points.*.lng,data_points.*.rank"
    IMAGE_HOST = "https://lf-static-v2.localfalcon.com"
    attr_reader :points

    # Only persist a detail response bound to the verified report and business.
    # Local Falcon can also return competitor lists and AI analysis. Neither belongs in a pin.
    def self.from_report(report, row, place)
      return unless report.is_a?(Hash) && report["platform"] == "google" && report["place_id"] == place &&
        report["report_key"] == row[:external_id] && report["keyword"].to_s.strip.casecmp?(row[:keyword])
      date = Date.strptime(report.fetch("date").split.first, "%m/%d/%Y")
      size = Integer(report.fetch("grid_size").to_s, 10)
      radius = Float(report.fetch("radius"))
      return unless radius.finite? && radius.positive? && %w[mi km].include?(report["measurement"])
      return unless date == row[:observed_on] && size == row[:metrics][:grid_size] && radius == row[:metrics][:radius] &&
        report["measurement"] == row[:metrics][:distance_unit]

      raw = report["data_points"]
      return unless raw.is_a?(Array) && raw.size.between?(1, size * size)
      points = raw.map do |point|
        return unless point.is_a?(Hash)
        lat = Float(point.fetch("lat"))
        lng = Float(point.fetch("lng"))
        return unless lat.between?(-90, 90) && lng.between?(-180, 180)
        rank = Integer(point["rank"].to_s, 10, exception: false)
        value = if point["rank"] == "20+" || (rank && rank > 20)
          "20+"
        elsif rank&.positive?
          rank
        end
        { "lat" => lat, "lng" => lng, "rank" => value }
      end
      return unless points.uniq { |p| p.values_at("lat", "lng") }.size == points.size
      { "report_key" => row[:external_id], "place_id" => place, "keyword" => row[:keyword], "date" => date.iso8601,
        "grid_size" => size, "radius" => radius, "unit" => report["measurement"], "points" => points,
        "street_map" => report["image"] == "#{IMAGE_HOST}/image/#{row[:external_id]}" }
    rescue KeyError, TypeError, ArgumentError
      nil
    end

    def initialize(snapshot)
      @snapshot = snapshot
      @grid = snapshot.map_grid || {}
      @points = if self.class.bound?(@grid, snapshot)
        @grid["points"]
      else
        []
      end
    end

    def self.bound?(grid, snapshot)
      expected_place = snapshot.metrics["place_id"]
      grid.is_a?(Hash) && (expected_place.blank? || grid["place_id"] == expected_place) &&
        grid["report_key"] == snapshot.external_id &&
        grid["keyword"].to_s.casecmp?(snapshot.keyword.to_s) && grid["date"] == snapshot.observed_on.iso8601 &&
        grid["grid_size"].to_s == snapshot.metrics["grid_size"].to_s && grid["points"].is_a?(Array)
    end

    def street_map_url
      "#{IMAGE_HOST}/image/#{@snapshot.external_id}" if points.any? && @grid["street_map"] && ReportReader::REPORT_KEY.match?(@snapshot.external_id)
    end

    def matches?(other)
      points.any? && other.points.any? && signature == other.signature
    end

    def signature
      @signature ||= [@grid.values_at("place_id", "grid_size", "radius", "unit"), points.map { |p| p.values_at("lat", "lng") }.sort]
    end

    # North is up. Unwrap longitude around the first pin so dateline scans stay together.
    def mapped_points
      return [] if points.empty?
      longitudes = points.map { |p| (p["lng"] - points.first["lng"] + 180) % 360 - 180 }
      west, east = longitudes.minmax
      south, north = points.map { |p| p["lat"] }.minmax
      points.each_with_index.map do |p, index|
        x = east == west ? 50 : 7.0 + 86.0 * (longitudes[index] - west) / (east - west)
        y = north == south ? 50 : 7.0 + 86.0 * (north - p["lat"]) / (north - south)
        p.merge("x" => x.round(3), "y" => y.round(3))
      end.sort_by { |p| [p["y"], p["x"]] }
    end
  end
end
