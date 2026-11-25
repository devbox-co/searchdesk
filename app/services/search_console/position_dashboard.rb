module SearchConsole
  class PositionDashboard
    attr_reader :records, :property, :day, :cutoff, :country, :rows

    def initialize(site:, requested_day: nil)
      @country = DailyPositions.country_for(site)
      @today = Time.current.in_time_zone(DailyPositions::ZONE).to_date
      terms = site.keywords.order(priority: :desc, phrase: :asc).to_a
      connection = site.search_console_connection
      @records = matching_records(site, connection, terms)
      scope = connection&.report&.fetch("daily_scope", {}) || {}
      @cutoff = parse_date(scope["through"]) if scope["country"] == country && scope["property"] == property
      @history = read_reports
      @day = requested_day || cutoff || @today
      @rows = terms.map { |term| compare(term, @history[term.phrase.downcase]) }
    end

    def available?
      rows.any? { |row| row[:baseline] }
    end

    # Count only explicit, final daily API values. An omitted low-volume query
    # and a reported row with zero clicks are different observations.
    def weekly_clicks(keywords)
      phrases = keywords.map { |keyword| keyword.phrase.downcase }.to_set
      as_of = [day, @today].min
      checked = {}
      records.each do |record|
        next unless record.metrics["source_basis"] == "final_api" && phrases.include?(record.keyword.downcase)
        dates = Array(record.metrics["queried_days"]).filter_map { |stamp| parse_date(stamp) }
        checked[record.id] = dates.select { |date| date <= as_of }
      end
      finish = checked.values.filter_map(&:max).max
      return unless finish

      dates = ((finish - 13)..finish).to_a
      changes = keywords.filter_map do |keyword|
        daily = @history.fetch(keyword.phrase.downcase, {})
        clicks = dates.map do |date|
          reading = daily[date]
          count = reading[:clicks] if reading && reading[:basis] == "final_api"
          count if count && count >= 0
        end
        next if clicks.any?(&:nil?)
        previous = clicks.first(7).sum
        current = clicks.last(7).sum
        { keyword: keyword, previous: previous, current: current, delta: current - previous }
      end
      snapshots = checked.filter_map { |id, days| id if days.any? { |date| date >= dates.first } }
      { finish: finish, changes: changes, snapshot_ids: snapshots }
    end

    private

    def matching_records(site, connection, terms)
      return [] if country.blank? || terms.empty?
      scope = DailyPositions.scope_for(site).where("LOWER(keyword) IN (?)", terms.map { |keyword| keyword.phrase.downcase })
      @property = connection&.property.presence
      # A URL-prefix and a domain property can represent different impressions.
      # While a new grant awaits property selection, only imported UI evidence is available.
      if property.nil?
        scope = scope.where("metrics->>'source_basis' = 'complete_ui_report'")
        property_expr = Arel.sql("metrics->>'property'")
        candidates = scope.group(property_expr).order(Arel.sql("MAX(observed_on) DESC, MAX(id) DESC")).pluck(property_expr)
        @property = candidates.find { |id| Client.matches?(id, site.host) }
      end
      return [] unless property && Client.matches?(property, site.host)
      scope.where("metrics->>'property' = ?", property).order(observed_on: :asc, id: :asc).to_a
    end

    def read_reports
      history = Hash.new { |hash, key| hash[key] = {} }
      # A final query report supersedes earlier UI exports for the days it checked.
      ordered = records.sort_by { |r| [r.metrics["source_basis"] == "final_api" ? 1 : 0, r.observed_on, r.id] }
      ordered.each do |record|
        bucket = history[record.keyword.downcase]
        basis = record.metrics["source_basis"]
        first = parse_date(record.metrics["start"])
        last = parse_date(record.metrics["end"])
        @cutoff = [cutoff, last].compact.max if last && last <= @today
        if basis == "final_api"
          Array(record.metrics["queried_days"]).each { |stamp| bucket.delete(parse_date(stamp)) }
        end
        Array(record.metrics["daily"]).each do |values|
          next unless values.is_a?(Hash)
          date = parse_date(values["date"])
          next unless date && date <= @today && (!first || date >= first) && (!last || date <= last)
          impressions = Integer(values["impressions"], exception: false)
          clicks = Integer(values["clicks"], exception: false)
          position = Float(values["average_position"], exception: false)
          position = nil unless impressions&.positive? && position&.finite? && position >= 1
          bucket[date] = { date: date, position: position, impressions: impressions, clicks: clicks, basis: basis, record: record }
        end
      end
      history
    end

    def compare(keyword, history)
      comparable = history.values.select { |data| data[:date] <= day && data[:position] }
      first, last = comparable.minmax_by { |data| data[:date] }
      current = history[day]
      change = first[:position] - current[:position] if first && current&.dig(:position) && first[:date] < day
      { keyword: keyword, current: current, baseline: first, latest: last, change: change }
    end

    def parse_date(value)
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end
  end
end
