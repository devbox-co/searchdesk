module SearchConsole
  class ReportBuilder
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
      return result.merge("keyword_pages" => [], "partial_detail" => false, "tracked_terms_read" => 0) if terms.empty?
      selected = terms.take(20)
      # RE2 literal quoting. Each request stays below Google's 4,096-character regex limit.
      data = selected.each_slice(5).flat_map do |group|
        expression = "^(?:" + group.map { |term| Regexp.escape(term).gsub("\\ ", " ") }.join("|") + ")$"
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
