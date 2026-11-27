module Tracking
  module GoogleAiOverview
    KEY = "google_ai_overview_v1"

    def self.read(items, host:)
      overview = items.find { |item| item["type"] == "ai_overview" && item["page"] == 1 }
      return unless overview

      components = Array(overview["items"]).grep(Hash)
      links = Array(overview["references"]).grep(Hash)
      components.each do |component|
        links.concat(Array(component["references"]).grep(Hash))
        links.concat(Array(component["links"]).grep(Hash))
        Array(component["expanded_element"]).grep(Hash).each do |expanded|
          links.concat(Array(expanded["references"]).grep(Hash))
          links.concat(Array(expanded["links"]).grep(Hash))
        end
      end
      return { "coverage" => "unavailable" } if components.empty? && links.empty?

      usable = links.filter_map { |link| ResultUrl.parse(link["url"]) }.uniq(&:to_s)
      cited = usable.any? { |url| ResultUrl.host_matches?(host, url.host) } unless usable.empty?
      { "coverage" => "provider_payload", "citation_count" => usable.size, "site_link_observed" => cited }
    end

    def self.sample(result, host:)
      overview = read(result.fetch("items"), host: host)
      return overview if overview

      types = result["item_types"]
      absent = types.is_a?(Array) && !types.include?("ai_overview") &&
        result.fetch("items").none? { |item| item["type"] == "ai_overview" }
      { "coverage" => absent ? "no_overview" : "unavailable" }
    end
  end
end
