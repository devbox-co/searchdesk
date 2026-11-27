require "csv"

module LocalFalcon
  class GeogridExport
    LIMIT = 20

    def self.scope(site)
      MapsSummary.verified_scan_scope(site).where.not(map_grid: nil)
    end

    def self.entry(snapshot)
      grid = ScanGrid.new(snapshot)
      reading = MapsSummary.new(snapshot)
      return if grid.points.empty?

      { "provider" => "Local Falcon", "platform" => "Google Maps", "reference" => snapshot.external_id,
        "observed_on" => snapshot.observed_on.iso8601, "keyword" => snapshot.keyword,
        "grid_size" => reading.grid_size, "radius" => reading.radius&.first, "unit" => reading.radius&.last,
        "share_of_local_voice" => reading.share, "average_rank" => reading.average_rank,
        "source_path" => "/source_snapshots/#{snapshot.id}",
        "points" => grid.points.map { |point| point.slice("lat", "lng", "rank") } }
    end

    def self.csv(entry)
      term = entry.fetch("keyword")
      term = "'#{term}" if term.match?(/\A[[:space:]]*[=+@-]/)
      CSV.generate do |csv|
        csv << %w[keyword latitude longitude rank provider_rank observed_on report_key]
        entry.fetch("points").each do |point|
          rank = point["rank"]
          csv << [term, point.fetch("lat"), point.fetch("lng"), (rank == "20+" ? 21 : rank), rank,
            entry.fetch("observed_on"), entry.fetch("reference")]
        end
      end
    end
  end
end
