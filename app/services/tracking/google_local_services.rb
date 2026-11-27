module Tracking
  module GoogleLocalServices
    KEY = "google_local_services_v1"
    GOOGLE_HOSTS = %w[google.com www.google.com google.co.uk www.google.co.uk].freeze
    COVERAGE = {
      "no_panel" => "No Local Services Ads panel was returned for this search sample.",
      "no_match" => "The panel was returned without an exact match for the verified Business Profile.",
      "ambiguous" => "More than one returned ad matched the verified Business Profile.",
      "unavailable" => "The provider panel could not be read reliably."
    }.freeze

    def self.read(items, profile:)
      return unless profile

      matching_type = items.select { |item| item["type"] == "local_services" }
      panels = matching_type.select { |item| item["page"] == 1 }
      sample = { "place_id" => profile.place_id }
      if panels.empty?
        coverage = matching_type.any? { |item| item["page"].nil? } ? "unavailable" : "no_panel"
        return sample.merge("coverage" => coverage)
      end

      rows = panels.first["items"]
      unless rows.is_a?(Array) && rows.size <= 100 &&
          rows.all? { |row| row.is_a?(Hash) && row["type"] == "local_services_element" }
        return sample.merge("coverage" => "unavailable")
      end

      matches = rows.each_index.select { |index| matches_profile?(rows.fetch(index), profile) }
      coverage = matches.one? ? "matched" : matches.empty? ? "no_match" : "ambiguous"
      sample.merge("coverage" => coverage, "ad_rows" => rows.size, "panel_position" => matches.one? ? matches.first + 1 : nil).compact
    end

    def self.description(sample)
      return "Matched listing at position #{sample.fetch('panel_position')} in the first Local Services panel." if sample["panel_position"]

      COVERAGE.fetch(sample["coverage"], COVERAGE.fetch("unavailable"))
    end

    def self.matches_profile?(row, profile)
      url = ResultUrl.parse(row["url"])
      return false unless url.is_a?(URI::HTTPS) && GOOGLE_HOSTS.include?(url.host.downcase) && url.port == 443

      ids = URI.decode_www_form(url.query.to_s).select { |name, _| name == "sabplaceid" }.map(&:last)
      ids == [profile.place_id]
    rescue ArgumentError
      false
    end
    private_class_method :matches_profile?
  end
end
