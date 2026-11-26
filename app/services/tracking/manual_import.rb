require "time"

module Tracking
  class ManualImport
    class Error < ArgumentError; end

    def self.call(series:, payload:)
      raise Error, "Use a manual tracking series" unless series.source == "manual"
      if payload.is_a?(String)
        raise Error, "Import limit is 256 KiB" if payload.bytesize > 262_144
        payload = JSON.parse(payload)
      end
      raise Error, "Expected a JSON object" unless payload.is_a?(Hash)
      data = payload.deep_stringify_keys
      %w[keyword location language device host depth source].each do |field|
        raise Error, "The #{field} does not match this series" unless data.fetch(field) == series.settings.fetch(field)
      end
      stamp = data.fetch("captured_at").to_s
      raise Error, "Capture time must include a UTC offset" unless stamp.match?(/(?:Z|[+-]\d\d:\d\d)\z/i)
      captured_at = Time.iso8601(stamp)
      RecordResult.call(series: series, captured_at: captured_at, items: data.fetch("items"),
                        metadata: { "source_label" => "Owner-imported organic observation" })
    rescue Error
      raise
    rescue KeyError, ArgumentError, TypeError, JSON::ParserError => e
      raise Error, e.message
    end
  end
end
