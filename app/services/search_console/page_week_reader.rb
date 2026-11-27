module SearchConsole
  class PageWeekReader
    PAGE_LIMIT = 2_000

    def initialize(client:, property:, country:, host:, token:)
      @client, @property, @country, @host, @token = client, property, country, host, token
    end

    def read(terms, week_start)
      filters = [
        {dimension: "country", operator: "equals", expression: @country.downcase},
        {dimension: "query", operator: "includingRegex", expression: "(?-i)^(?:#{terms.map { |t| Regexp.escape(t).gsub("\\ ", " ") }.join("|")})$"}
      ]
      @payload = {startDate: week_start.iso8601, endDate: (week_start + 6).iso8601,
        type: "web", dataState: "final", dimensionFilterGroups: [{filters: filters}]}
      receipts = terms.product(SearchConsolePageWeek::DEVICES).index_with do |query, device|
        {query: query, device: device, week_start: week_start, pages: [], partial: false, clicks: nil, impressions: nil}
      end
      totals = request(%w[query device], "byProperty", terms.size * 3 + 1)
      totals.each do |row|
        keyword, device = keys(row, 2, terms)
        next unless (receipt = receipts[[keyword, device]])
        raise Client::Error, "Google returned duplicate weekly query totals." unless receipt[:clicks].nil?
        receipt[:clicks], receipt[:impressions] = counts(row)
      end

      page_rows = request(%w[query device page], "byPage", PAGE_LIMIT + 1)
      receipts.each_value { |r| r[:partial] = true } if page_rows.size > PAGE_LIMIT
      seen = Set.new
      page_rows.first(PAGE_LIMIT).each do |row|
        query, device, url = keys(row, 3, terms)
        next unless (receipt = receipts[[query, device]])
        unless eligible_page?(url)
          receipt[:partial] = true
          next
        end
        raise Client::Error, "Google returned duplicate weekly page evidence." unless seen.add?([query, device, url])
        clicks, impressions = counts(row)
        next if impressions.zero?
        position = Float(row.fetch("position"))
        raise Client::Error, "Google returned an invalid weekly page position." unless position.finite? && position >= 1
        receipt[:pages] << {"url" => url, "clicks" => clicks, "impressions" => impressions, "position" => position}
      end
      receipts.values
    end

    private

    def request(dimensions, aggregation, limit)
      rows = @client.query(token: @token.call, property: @property,
        payload: @payload.merge(dimensions: dimensions, aggregationType: aggregation, rowLimit: limit))
      unless rows.is_a?(Array) && rows.size <= limit && rows.all? { |row| row.is_a?(Hash) }
        raise Client::Error, "Google returned an invalid weekly page report."
      end
      rows
    end

    def keys(row, count, terms)
      values = row.fetch("keys")
      unless values.is_a?(Array) && values.size == count && terms.include?(values.first) &&
          %w[DESKTOP MOBILE TABLET].include?(values[1].to_s.upcase)
        raise Client::Error, "Google returned a page report outside the requested scope."
      end
      [values.first, values[1].downcase, *values.drop(2)]
    end

    def counts(row)
      counts = %w[clicks impressions].map do |field|
        value = row.fetch(field)
        raise Client::Error, "Google returned an invalid weekly count." unless value.is_a?(Numeric) && value.finite? && value >= 0 && value == value.to_i
        value.to_i
      end
      raise Client::Error, "Google returned inconsistent weekly counts." if counts.first > counts.last
      counts
    end

    def eligible_page?(value)
      return false unless value.is_a?(String) && value.bytesize <= 2048
      uri = Tracking::ResultUrl.parse(value)
      uri && uri.port == uri.default_port && !uri.query && !uri.fragment && Tracking::ResultUrl.host_matches?(@host, uri.host)
    end
  end
end
