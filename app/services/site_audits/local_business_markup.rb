module SiteAudits
  module LocalBusinessMarkup
    TYPES = %w[LocalBusiness Restaurant Store MedicalBusiness Dentist Physician Plumber Electrician
      HVACBusiness HairSalon AutoRepair LegalService RealEstateAgent ProfessionalService MedicalClinic
      Optician Pharmacy HealthAndBeautyBusiness BeautySalon DaySpa NailSalon TattooParlor
      HomeAndConstructionBusiness Locksmith RoofingContractor MovingCompany GeneralContractor
      FoodEstablishment CafeOrCoffeeShop Bakery BarOrPub LodgingBusiness Hotel HealthClub].freeze
    EVIDENCE_VERSION = 2
    EXTENDED_FIELDS = %w[businessType geo openingHoursSpecification].freeze
    FIELD_LABELS = { "businessType" => "Business type", "geo" => "Map coordinates",
      "openingHoursSpecification" => "Opening hours" }.freeze

    ADDRESS_PROPERTIES = %w[streetAddress addressLocality addressRegion postalCode addressCountry].freeze

    def self.extract(document, page_url, site_host)
      nodes = document.css("script[type]").select do |script|
        script["type"].to_s.strip.casecmp?("application/ld+json")
      end.first(12).flat_map { |script| graph_nodes(script.text) }
      matches = nodes.select do |node|
        types(node).any? && same_storefront_page?(page_url, node)
      end
      fingerprint(matches.first, site_host) if matches.one?
    end

    def self.fingerprint(node, site_host)
      key = Rails.application.key_generator.generate_key("Searchdesk local business markup #{site_host}", 32)
      address = node["address"].is_a?(Hash) ? node["address"].slice(*ADDRESS_PROPERTIES) : {}
      values = node.slice("name", "telephone").merge(address)
      result = values.each_with_object({}) do |(field, value), result|
        next unless value.is_a?(String) && value.present?

        normalized = value.unicode_normalize(:nfkc).squish.downcase
        normalized = normalized.gsub(/[^0-9+]/, "") if field == "telephone"
        result[field] = OpenSSL::HMAC.hexdigest("SHA256", key, normalized)
      end
      if (business_types = types(node)).any?
        result["businessType"] = business_types.map { |type| digest(key, type) }
      end
      if node.key?("geo")
        geo = node["geo"]
        pair = coordinates(geo["latitude"], geo["longitude"]) if geo.is_a?(Hash)
        result["geo"] = digest(key, pair.map { |value| format("%.5f", value.round(5).zero? ? 0 : value) }.join(",")) if pair
        result["geo"] ||= nil
      end
      if node.key?("openingHoursSpecification") || node.key?("openingHours")
        hours = if node.key?("openingHoursSpecification")
          StorefrontHours.normalize(node["openingHoursSpecification"])
        elsif Array.wrap(node["openingHours"]).all? { |entry| entry.is_a?(String) }
          StorefrontHours.parse_text(Array.wrap(node["openingHours"]).join(" | "))
        end
        result["openingHoursSpecification"] = hours && digest(key, hours.to_json)
      end
      result
    end

    def self.coordinates(latitude, longitude)
      lat, lng = [latitude, longitude].map { |value| Float(value, exception: false) }
      [lat, lng] if lat&.between?(-90, 90) && lng&.between?(-180, 180)
    end

    def self.types(node)
      Array.wrap(node["@type"]).grep(String)
        .map { |type| type.sub(%r{\Ahttps?://schema\.org/}, "") } & TYPES
    end

    def self.same_storefront_page?(page_url, node)
      return Tracking::ResultUrl.same_page?(page_url, node["url"]) if node["url"].present?

      id = node["@id"]
      return false unless id.is_a?(String) && id.start_with?("https://", "http://", "#")

      target = URI.join(page_url, id)
      target.fragment = nil
      Tracking::ResultUrl.same_page?(page_url, target.to_s)
    rescue URI::Error
      false
    end

    def self.digest(key, value)
      OpenSSL::HMAC.hexdigest("SHA256", key, value)
    end

    def self.graph_nodes(text)
      return [] if text.bytesize > 64.kilobytes

      parsed = JSON.parse(text, max_nesting: 32)
      nodes = parsed.is_a?(Hash) ? [parsed] + Array.wrap(parsed["@graph"]) : Array.wrap(parsed)
      nodes.first(80).grep(Hash)
    rescue JSON::ParserError
      []
    end
    private_class_method :graph_nodes, :types, :same_storefront_page?, :digest
  end
end
