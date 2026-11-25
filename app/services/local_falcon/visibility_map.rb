module LocalFalcon
  class VisibilityMap
    attr_reader :scan, :grid, :options, :history

    def initialize(site:, through:, report_id: nil)
      scans = MapsSummary.scan_scope(site).where(observed_on: ..through).order(observed_on: :desc, id: :desc)
      @options = scans.limit(60).pluck(:external_id, :keyword, :observed_on)
      @history = []
      return if @options.empty?
      selected = scans.find_by(external_id: report_id) if ReportReader::REPORT_KEY.match?(report_id.to_s)
      selected ||= scans.first
      @scan = MapsSummary.new(selected)
      @grid = ScanGrid.new(selected)
      @options << [selected.external_id, selected.keyword, selected.observed_on] unless @options.any? { |key,| key == selected.external_id }

      if @grid.points.any?
        recent = scans.where("LOWER(keyword) = ?", selected.keyword.downcase).where(observed_on: ..selected.observed_on)
          .where.not(map_grid: nil).limit(40)
        @history = recent.filter_map do |candidate|
          summary = MapsSummary.new(candidate)
          summary if summary.share && @grid.matches?(ScanGrid.new(candidate))
        end.first(6).reverse
      end
    end

    def counts
      return unless scan
      scan.top_three_counts || begin
        points = grid.points
        if points.any? && points.none? { |p| p["rank"].nil? }
          [points.count { |p| (1..3).cover?(p["rank"]) }, points.length]
        end
      end
    end
  end
end
