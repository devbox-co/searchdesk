module SearchConsole
  class PerformanceOverview
    attr_reader :current, :previous, :report, :connection

    def initialize(site)
      @connection = site.search_console_connection
      return unless connection && %w[connected delayed].include?(connection.status) &&
        Client.matches?(connection.property, site.host)
      candidate = connection.report
      return unless candidate.is_a?(Hash) && candidate["property"] == connection.property &&
        candidate["search_type"] == "web" && candidate["data_state"] == "final"

      @report = candidate
      @current = period(report["current"])
      prior = period(report["previous"])
      @previous = prior if current && prior && prior[:end] + 1 == current[:start]
    end

    def series(metric)
      return [] unless current && %w[clicks impressions].include?(metric)
      rows = Array(report["performance_days"]).index_by { |row| row["date"] if row.is_a?(Hash) }
      (current[:start]..current[:end]).map do |day|
        value = rows.dig(day.iso8601, metric)
        { date: day, value: value.is_a?(Integer) && value >= 0 ? value : nil }
      end
    end

    private

    def period(raw)
      return unless raw.is_a?(Hash)
      first = Date.iso8601(raw.fetch("start"))
      last = Date.iso8601(raw.fetch("end"))
      return unless last == first + 27
      { start: first, end: last, metrics: raw["metrics"] }
    rescue Date::Error, KeyError, TypeError
      nil
    end
  end
end
