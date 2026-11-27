module LocalSeoData
  module BusinessProfile
    LABELS = {
      "name" => "Business name", "address" => "Address", "phone" => "Phone",
      "website" => "Website", "categories" => "Categories", "hours" => "Opening hours"
    }.freeze

    def self.summary(data, place_id:, site:)
      raise Client::Unavailable unless data["matched"] == true && data["place_id"] == place_id

      key = Rails.application.key_generator.generate_key("Searchdesk M3 #{site.id} #{site.host}", 32)
      fields = LABELS.keys.filter_map do |field|
        next unless data.key?(field)

        value = normalize(field, data[field])
        next if value.nil?

        # An explicit null or blank value can be compared with an earlier value.
        # An omitted field instead means the provider did not measure it.
        [field, { "present" => value.present?, "digest" => OpenSSL::HMAC.hexdigest("SHA256", key, value.to_json) }]
      end.to_h
      raise Client::Unavailable if fields.empty?

      { "fields" => fields }
    end

    def self.normalize(field, value)
      return "" if value.nil?

      case field
      when "hours"
        return unless value.is_a?(Hash) && value.size <= 14 &&
          value.all? { |day, hours| public_string?(day) && public_string?(hours) }

        value.sort.to_h.transform_values(&:squish)
      when "categories"
        return unless value.is_a?(Array) && value.size <= 30 && value.all? { |category| public_string?(category) }

        value.map(&:squish).uniq.sort
      else
        return unless public_string?(value)

        value.squish
      end
    end

    def self.public_string?(value)
      value.is_a?(String) && value.bytesize <= 1000 && !value.match?(/[[:cntrl:]]/)
    end
    private_class_method :normalize, :public_string?
  end
end
