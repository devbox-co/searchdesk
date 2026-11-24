module Analytics
  class Client < GoogleReadOnly::Client
    SCOPE = "https://www.googleapis.com/auth/analytics.readonly"
    CALLBACK_ROUTE = :callback_analytics_url
    ADMIN = "https://analyticsadmin.googleapis.com/v1beta"
    DATA = "https://analyticsdata.googleapis.com/v1beta"
    METRICS = %w[sessions engagedSessions keyEvents].freeze

    def self.readonly_scope?(scope)
      scope.is_a?(String) && scope.split == [SCOPE]
    end

    def self.property_id(input)
      input.to_s.strip[/\A(?:properties\/)?([1-9]\d{0,19})\z/, 1]
    end

    def binding(token:, property:, host:)
      id = self.class.property_id(property)
      raise Error, "Enter the numeric GA4 property ID from Admin → Property details." unless id
      uri = "#{ADMIN}/properties/#{id}"
      data = json_request(uri, token: token)
      zone = data["timeZone"]
      unless data["name"] == "properties/#{id}" && zone.is_a?(String) && ActiveSupport::TimeZone[zone]
        raise Error, "Google did not return a readable GA4 property and reporting time zone."
      end
      matching_ids = []
      seen = []
      cursor = nil
      loop do
        query = { pageSize: 100, fields: "dataStreams(name,type,webStreamData/defaultUri),nextPageToken" }
        query[:pageToken] = cursor if cursor
        page = json_request("#{uri}/dataStreams?#{URI.encode_www_form(query)}", token: token)
        streams = page.fetch("dataStreams", [])
        raise Error, "Google returned invalid Analytics web streams." unless streams.is_a?(Array) && streams.all?(Hash)
        streams.each do |stream|
          next unless stream["type"] == "WEB_DATA_STREAM"
          stream_host = Tracking::ResultUrl.parse(stream.dig("webStreamData", "defaultUri"))&.host
          next unless stream_host && Tracking::ResultUrl.host_matches?(host, stream_host)
          stream_id = stream["name"].to_s[%r{\Aproperties/#{id}/dataStreams/([1-9]\d*)\z}, 1]
          matching_ids << stream_id if stream_id
        end
        cursor = page["nextPageToken"].presence
        break unless cursor
        raise Error, "Google returned an incomplete stream list. Try again later." if !cursor.is_a?(String) || seen.include?(cursor) || seen.size >= 100
        seen << cursor
      end
      raise AccessError, "This property has no Google Analytics web stream matching #{host}. Check the property ID and its default stream URL." if matching_ids.empty?
      { property_id: id, property_name: data["displayName"].to_s.first(200), property_zone: zone, verified_host: host, stream_ids: matching_ids.uniq.sort }
    end

    def period(token:, binding:, from:, through:)
      host = binding.fetch(:verified_host).delete_prefix("www.")
      filters = [list_filter("hostName", [host, "www.#{host}"]), list_filter("streamId", binding.fetch(:stream_ids)),
                 list_filter("sessionSource", ["google"]), list_filter("sessionMedium", ["organic"])]
      request = { dateRanges: [{ startDate: from.iso8601, endDate: through.iso8601 }],
                  dimensionFilter: { andGroup: { expressions: filters } }, metrics: METRICS.map { |n| { name: n } } }
      data = json_request("#{DATA}/properties/#{binding.fetch(:property_id)}:runReport", token: token, json: request)
      headers = data.fetch("metricHeaders", [])
      rows = data.fetch("rows", [])
      unless headers.is_a?(Array) && headers.all?(Hash) && headers.pluck("name") == METRICS &&
             rows.is_a?(Array) && rows.size <= 1 && rows.all?(Hash) && data.fetch("rowCount", rows.size) == rows.size
        raise Error, "Google returned an incomplete Analytics report."
      end
      metadata = data.fetch("metadata", {})
      raise Error, "Google returned invalid Analytics report metadata." unless metadata.is_a?(Hash)
      if metadata.dig("schemaRestrictionResponse", "activeMetricRestrictions").present?
        raise AccessError, "Google restricted one or more requested Analytics metrics. Check property reporting access."
      end
      if rows.any?
        cells = rows.first["metricValues"]
        raise Error, "Google returned incomplete Analytics totals." unless cells.is_a?(Array) && cells.all?(Hash)
        values = cells.pluck("value")
      end
      if values && (values.size != 3 || !values[0, 2].all? { |v| v.to_s.match?(/\A\d+\z/) } || !values[2].to_s.match?(/\A\d+(?:\.\d+)?\z/))
        raise Error, "Google returned invalid Analytics totals."
      end
      { "start" => from.iso8601, "end" => through.iso8601, "metrics" => values && {
        "sessions" => Integer(values[0]), "engaged_sessions" => Integer(values[1]), "unverified_key_events" => BigDecimal(values[2].to_s).to_f
      }, "subject_to_thresholding" => metadata["subjectToThresholding"] == true,
         "sampled" => metadata["samplingMetadatas"].present?, "data_loss_from_other_row" => metadata["dataLossFromOtherRow"] == true }
    end

    private

    def list_filter(field, values)
      { filter: { fieldName: field, inListFilter: { values: values, caseSensitive: false } } }
    end
  end
end
