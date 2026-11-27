module SeoWorkflows
  module LandingPageBrief
    KIND = "landing_page_brief"
    ADDRESS = {
      "street_address" => "streetAddress", "locality" => "addressLocality",
      "region" => "addressRegion", "postal_code" => "postalCode", "country_code" => "addressCountry"
    }.freeze
    OPTIONAL_SCHEMA_FIELDS = %w[business_type latitude longitude opening_hours].freeze
    PUBLIC_FIELDS = ADDRESS.keys + %w[business_name telephone] + OPTIONAL_SCHEMA_FIELDS

    def self.summarize(site, rows)
      invalid!("Use at most 20 landing page briefs.") if rows.size > 20

      base = URI("https://#{site.host}/")
      scope = SiteAudits::PublicUrl.new(site.host)
      records = rows.map do |row|
        page = scope.resolve(row["page"], base: base)
        invalid!("Each page must be a public URL on this site.") unless page

        brief = { "page" => page.path, "heading" => plain_text(row, "heading", 140),
          "paragraph" => plain_text(row, "paragraph", 500) }.compact
        schema = row["draft_storefront_schema"].to_s.strip.downcase
        invalid!("Use true, false or blank for draft_storefront_schema.") unless ["", "true", "false"].include?(schema)
        if schema == "true"
          brief["storefront"] = storefront(row, page)
        elsif PUBLIC_FIELDS.any? { |key| row[key].present? }
          invalid!("Supply business contact and address fields only for a public storefront schema draft.")
        end
        invalid!("Supply a heading, a paragraph or public storefront details.") if brief.size == 1
        brief
      end
      invalid!("Use one brief per page.") unless records.pluck("page").uniq.size == records.size
      invalid!("Choose one page for the storefront schema draft.") if records.count { |row| row.key?("storefront") } > 1

      { "records" => records }
    end

    def self.storefront(row, page)
      name = plain_text(row, "business_name", 160)
      phone = plain_text(row, "telephone", 35)
      address = ADDRESS.to_h { |key, property| [property, plain_text(row, key, 160)] }
      valid_phone = phone&.match?(/\A\+[1-9][0-9]{6,14}\z/)
      country = address["addressCountry"]
      invalid!("Provide the public storefront name, street address, locality, two-letter country code and international phone number.") unless
        name && valid_phone && address["streetAddress"] && address["addressLocality"] && country&.match?(/\A[A-Z]{2}\z/)

      type = plain_text(row, "business_type", 80) || "LocalBusiness"
      invalid!("Use a supported Schema.org LocalBusiness type.") unless SiteAudits::LocalBusinessMarkup::TYPES.include?(type)
      schema = { "@context" => "https://schema.org", "@type" => type, "@id" => "#{page}#localbusiness",
        "name" => name, "url" => page.to_s, "telephone" => phone,
        "address" => { "@type" => "PostalAddress" }.merge(address.compact) }
      if row["latitude"].present? || row["longitude"].present?
        lat, lng = coordinates(row)
        schema["geo"] = { "@type" => "GeoCoordinates", "latitude" => lat, "longitude" => lng }
      end
      if row["opening_hours"].present?
        periods = SiteAudits::StorefrontHours.parse_text(row["opening_hours"])
        invalid!("Use weekly opening hours such as Mo-Fr 09:00-17:00 | Sa 10:00-14:00.") unless periods
        schema["openingHoursSpecification"] = SiteAudits::StorefrontHours.specifications(periods)
      end
      schema
    end

    def self.coordinates(row)
      raw = %w[latitude longitude].map { |key| row[key].to_s.strip }
      format_valid = raw.all? { |value| value.match?(/\A-?\d{1,3}\.\d{5,9}\z/) }
      values = SiteAudits::LocalBusinessMarkup.coordinates(*raw) if format_valid
      invalid!("Provide both public storefront coordinates with five to nine decimal places in range.") unless values
      values
    end

    def self.plain_text(row, key, length)
      value = row[key].to_s.squish
      return if value.empty?

      invalid!("Check the public text for #{key.humanize.downcase}.") if
        value.length > length || value.match?(/[<>[:cntrl:]]|\b[\w.+-]+@[\w.-]+\.[a-z]{2,}\b/i)
      value
    end

    def self.invalid!(message)
      raise EvidenceImport::InvalidExport, message
    end
    private_class_method :storefront, :coordinates, :plain_text, :invalid!
  end
end
