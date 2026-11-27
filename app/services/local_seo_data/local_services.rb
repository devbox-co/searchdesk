module LocalSeoData
  module LocalServices
    TOP = 3

    def self.settings
      keyword = ENV["LOCALSEODATA_LSA_KEYWORD"].to_s.squish
      market = ENV["LOCALSEODATA_LOCATION"].to_s.squish
      business = ENV["LOCALSEODATA_BUSINESS_NAME"].to_s.squish
      phone = digits(ENV["LOCALSEODATA_LSA_PHONE"])
      return unless phone && [keyword, market, business].all? { |text| public_text?(text) }

      { keyword: keyword, location: market, business_name: business, phone: phone }
    end

    def self.summarize(response, input:, site:)
      arrays = response.values_at("ads", "results").compact.uniq
      raise Client::Unavailable unless arrays.one? && arrays.first.is_a?(Array) && arrays.first.size <= 250

      rows = arrays.first
      meta = response["search_metadata"]
      if meta
        matches = meta.is_a?(Hash) && %w[keyword location].all? do |field|
          !meta.key?(field) || display_name(meta[field]) == display_name(input.fetch(field.to_sym))
        end
        raise Client::Unavailable unless matches
      end

      valid_rows = rows.all? do |row|
        row.is_a?(Hash) && row["position"].is_a?(Integer) && row["position"].between?(1, 250)
      end
      raise Client::Unavailable unless valid_rows && rows.pluck("position").uniq.size == rows.size

      target = rows.select do |row|
        display_name(row["business_name"]) == display_name(input.fetch(:business_name)) &&
          digits(row["phone"]) == input.fetch(:phone)
      end
      status = if rows.empty?
        "no_ads_returned"
      elsif target.one?
        "matched"
      elsif target.many?
        "ambiguous"
      else
        "no_verified_match"
      end

      # Keep identifiers for comparable top-three slots without retaining telephone numbers.
      top = rows.select { |row| row["position"] <= TOP }.sort_by { |row| row.fetch("position") }
      competitors = top.filter_map do |row|
        phone = digits(row["phone"])
        name = display_name(row["business_name"])
        next unless phone && name

        { "id" => fingerprint(site, name, phone), "name" => row.fetch("business_name").squish,
          "position" => row.fetch("position"), "tracked" => target.one? && row.equal?(target.first) }
      end
      complete_top_three = competitors.pluck("position") == [1, 2, 3] &&
        competitors.pluck("id").uniq.size == TOP

      {
        "query" => input.fetch(:keyword), "market" => input.fetch(:location), "coverage" => status,
        "ad_rows" => rows.size, "listing_position" => target.one? ? target.first.fetch("position") : nil,
        "top_three" => complete_top_three ? competitors : nil
      }.compact
    end

    def self.scope_digest(site, input)
      fingerprint(site, "scope", JSON.generate(input))
    end

    def self.fingerprint(site, name, value)
      key = Rails.application.key_generator.generate_key("Searchdesk LSA #{site.id} #{site.host}", 32)
      OpenSSL::HMAC.hexdigest("SHA256", key, "#{name}\0#{value}")
    end

    def self.display_name(value)
      value.unicode_normalize(:nfkc).squish.downcase if value.is_a?(String) && public_text?(value.squish)
    end

    def self.digits(value)
      return unless value.is_a?(String) && value.match?(/\A[+0-9() .-]{7,40}\z/)

      normalized = value.gsub(/[^0-9]/, "")
      normalized if normalized.size.between?(7, 15)
    end

    def self.public_text?(text)
      text.length.between?(1, 160) && !text.match?(/[<>[:cntrl:]]|[\w.+-]+@[\w.-]+\.[a-z]{2,}/i)
    end
    private_class_method :fingerprint, :display_name, :digits, :public_text?
  end
end
