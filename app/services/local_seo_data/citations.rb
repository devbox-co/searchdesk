module LocalSeoData
  module Citations
    DIRECTORIES = {
      "google" => 1, "apple" => 1, "bing" => 1, "facebook" => 1, "yelp" => 1,
      "yellowpages" => 2, "superpages" => 2, "bbb" => 2, "mapquest" => 2,
      "chamberofcommerce" => 3, "manta" => 3, "merchantcircle" => 3,
      "ezlocal" => 3, "citysquares" => 3, "hotfrog" => 3
    }.freeze
    CHECKED = %w[consistent inconsistent unverified not_found].freeze
    UNAVAILABLE = %w[check_failed unsupported defunct covered_by].freeze

    def self.summarize(data)
      details = data["details"]
      raise Client::Unavailable unless details.is_a?(Array) && details.size <= DIRECTORIES.size &&
        details.all? { |row| row.is_a?(Hash) && DIRECTORIES.key?(row["directory"]) } &&
        details.pluck("directory").uniq.size == details.size

      supplied = details.index_by { |row| row.fetch("directory") }
      records = DIRECTORIES.filter_map do |directory, tier|
        row = supplied[directory]
        next unless row

        status = row["status"]
        next if UNAVAILABLE.include?(status)
        raise Client::Unavailable unless CHECKED.include?(status)

        if status == "not_found"
          issues = ["missing_listing"]
          comparable = true
        else
          others = row.fetch("other_listings", [])
          raise Client::Unavailable unless others.is_a?(Array) && others.all?(Hash)

          fields = [row, *others].map { |listing| listing.values_at("name_match", "address_match", "phone_match") }
          raise Client::Unavailable unless fields.flatten.all? { |flag| [true, false, nil].include?(flag) }

          issues = SeoWorkflows::StructuredEvidence::CITATION_FIELDS.each_with_index.filter_map do |field, index|
            "#{field}_mismatch" if fields.any? { |flags| flags[index] == false }
          end
          issues << "duplicate_listings" if others.any?
          comparable = status != "unverified" && fields.flatten.none?(&:nil?)
        end
        { "directory" => directory, "tier" => tier, "issues" => issues, "comparable" => comparable }
      end
      { "records" => records, "directories_unavailable" => DIRECTORIES.size - records.size }
    end
  end
end
