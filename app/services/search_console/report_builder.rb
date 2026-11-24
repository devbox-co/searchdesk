module SearchConsole
  class ReportBuilder
    attr_reader :position_rows, :position_terms, :position_start, :position_end, :position_country

    def initialize(client:, token:, property:, site:)
      @client, @token, @property, @site = client, token, property, site
    end

    def call
      today = Time.current.in_time_zone("Pacific Time (US & Canada)").to_date
      dated = rows(today - 30, today, dimensions: ["date"], rowLimit: 31)
      days = dated.map { |r| Date.iso8601(r.fetch("keys").fetch(0)) }.select { |d| d >= today - 30 && d < today }
      last = days.max
      finish = last || today - 3
      current = totals(finish - 27, finish)
      prior = totals(finish - 55, finish - 28)
      terms = @site.keywords.order(priority: :desc, phrase: :asc).limit(21).pluck(:phrase)
      result = { "source" => "Google Search Console", "property" => @property, "time_zone" => "America/Los_Angeles",
        "search_type" => "web", "data_state" => "final", "country_scope" => "All countries",
        "last_reported_day" => last&.iso8601, "current" => current, "previous" => prior }
      @position_country = DailyPositions.country_for(@site)
      @position_terms = @site.keywords.order(:id).pluck(:phrase)
      @position_rows = []
      if @position_country && last && @position_terms.any?
        @position_end = last
        @position_start = last - 27
        @position_rows = fetch_positions
        result["daily_scope"] = { "country" => @position_country, "property" => @property,
          "through" => last.iso8601, "start" => @position_start.iso8601,
          "tracked_terms_read" => @position_terms.length, "method" => DailyPositions::METHOD }
      end
      return result.merge("keyword_pages" => [], "partial_detail" => false, "tracked_terms_read" => 0) if terms.empty?
      selected = terms.take(20)
      # RE2 literal quoting. Each request stays below Google's 4,096-character regex limit.
      data = selected.each_slice(5).flat_map do |group|
        expression = term_expression(group)
        rows(finish - 27, finish, dimensions: %w[query page device], rowLimit: 1001,
          dimensionFilterGroups: [{ filters: [{ dimension: "query", operator: "includingRegex", expression: expression }] }])
      end
      details = data.filter_map do |r|
        query, page, device = r.fetch("keys")
        url = Tracking::ResultUrl.parse(page)
        next unless selected.include?(query) && %w[MOBILE DESKTOP TABLET].include?(device.to_s.upcase) && url && !url.query && !url.fragment && Tracking::ResultUrl.host_matches?(@site.host, url.host)
        metrics(r).merge("keyword" => query, "page" => page, "device" => device)
      end
      result.merge("keyword_pages" => details.take(1000), "partial_detail" => data.length >= 1000 || data.length != details.length || terms.length > 20,
        "tracked_terms_read" => selected.length)
    end

    private

    def term_expression(group)
      "^(?:" + group.map { |term| Regexp.escape(term).gsub("\\ ", " ") }.join("|") + ")$"
    end

    def fetch_positions
      found = {}
      @position_terms.group_by(&:downcase).keys.each_slice(5) do |group|
        filters = [
          { dimension: "country", operator: "equals", expression: @position_country.downcase },
          { dimension: "query", operator: "includingRegex", expression: "(?-i)#{term_expression(group)}" }
        ]
        evidence = rows(@position_start, @position_end, dimensions: %w[date query], aggregationType: "byProperty",
          rowLimit: 5 * 28 + 1, dimensionFilterGroups: [{filters: filters}])
        evidence.each do |row|
          stamp, query = row.fetch("keys")
          day = Date.iso8601(stamp)
          key = query.to_s
          raise Client::Error, "Google returned daily results outside the requested scope" unless day.between?(@position_start, @position_end) && group.include?(key)
          identity = [stamp, key]
          raise Client::Error, "Google returned conflicting rows for one query and date" if found.key?(identity)
          values = metrics(row)
          raise Client::Error, "Google returned an invalid average position" if values["impressions"].positive? && values["position"] < 1
          found[identity] = { "date" => day.iso8601, "keyword" => key, "clicks" => values["clicks"],
            "impressions" => values["impressions"], "average_position" => values["impressions"].positive? ? values["position"] : nil }
        end
      end
      found.values
    end

    def rows(from, to, **opts)
      rows = @client.query(token: @token, property: @property, payload: { startDate: from.iso8601, endDate: to.iso8601,
        type: "web", dataState: "final" }.merge(opts))
      raise Client::Error, "Google returned malformed rows" unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) && (!opts[:dimensions] || (row["keys"].is_a?(Array) && row["keys"].length == opts[:dimensions].length)) }
      rows
    end

    def totals(from, to)
      row = rows(from, to, aggregationType: "byProperty", rowLimit: 1).first
      { "start" => from.iso8601, "end" => to.iso8601, "metrics" => row && metrics(row) }
    end

    def metrics(row)
      metrics = { "clicks" => Integer(row.fetch("clicks")), "impressions" => Integer(row.fetch("impressions")),
        "ctr" => Float(row.fetch("ctr")), "position" => Float(row.fetch("position")) }
      unless metrics.values.all? { |value| value.finite? && value >= 0 } && metrics["ctr"] <= 1
        raise Client::Error, "Google returned invalid metrics"
      end
      metrics
    end
  end
end
