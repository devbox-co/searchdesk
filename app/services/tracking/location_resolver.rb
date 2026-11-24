module Tracking
  class LocationResolver
    class Error < ArgumentError; end

    def self.resolve!(name:, country:, expected_code: nil, client: DataForSeo.new)
      country = country.to_s.strip.upcase
      raise Error, "Enter a two-letter country code such as GB or US." unless country.match?(/\A[A-Z]{2}\z/)
      label = normalized(name)
      raise Error, "Enter a town or a full provider location name." if label.empty? || label.length > 180
      if expected_code && !expected_code.to_s.match?(/\A[1-9]\d{0,9}\z/)
        raise Error, "The supplied provider location identifier is invalid."
      end
      entries = client.locations(country)
      matches = entries.select do |row|
        official = row["location_name"].to_s
        row["country_iso_code"].to_s.upcase == country &&
          (normalized(official) == label || normalized(official.split(",").first) == label) &&
          (!expected_code || row["location_code"].to_s == expected_code.to_s)
      end.uniq { |entry| entry["location_code"] }
      raise Error, "No matching Google location was found in #{country}. Check the town, region and country." if matches.empty?
      if matches.size > 1
        names = matches.first(5).map { |m| m.fetch("location_name") }.join(" or ")
        raise Error, "Choose the full location name for your area: #{names}."
      end
      match = matches.first
      canonical = match.fetch("location_name")
      { location: canonical, rank_location_name: canonical, rank_location_code: Integer(match.fetch("location_code")),
        rank_country_code: country, rank_location_verified_at: Time.current }
    rescue DataForSeo::Unavailable, DataForSeo::Rejected, DataForSeo::ScopeError, KeyError, TypeError
      raise Error, "The location catalogue is unavailable. Try again later or track using manual imports."
    end

    def self.normalized(value)
      value.to_s.unicode_normalize(:nfkc).downcase.split(",").map(&:squish).join(",")
    end
  end
end
