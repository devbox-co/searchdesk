module SeoWorkflows
  module StructuredEvidence
    TYPES = {
      "review_activity" => "Weekly review activity",
      "citation_audit" => "Citation NAP audit"
    }.freeze
    CITATION_FIELDS = %w[name address phone].freeze
    CITATION_STATUSES = %w[listed missing unverified].freeze

    def self.summarize(kind, rows, observed_on)
      records = if kind == "review_activity"
        weeks = rows.map { |row| review_week(row, observed_on) }
        invalid!("Each Sunday must appear only once.") unless weeks.pluck("week_ending").uniq.size == weeks.size
        weeks
      else
        rows.group_by { |row| directory(row) }.map { |host, listings| citation(host, listings) }
      end
      { "records" => records }
    end

    def self.review_week(row, observed_on)
      week = Date.iso8601(row["week_ending"].to_s)
      invalid!("Use a Sunday before the observation date.") unless week.sunday? && week < observed_on

      new_reviews = count(row["new_reviews"])
      new_one_star = count(row["new_one_star"])
      unanswered = count(row["unanswered_low_rating"])
      average = Float(row["average_rating"].to_s, exception: false)
      invalid!("Use whole review counts and an average rating from one to five, or leave the rating empty.") unless
        new_one_star <= new_reviews && (row["average_rating"].blank? || average&.between?(1, 5))

      { "week_ending" => week.iso8601, "new_reviews" => new_reviews, "average_rating" => average&.round(2),
        "unanswered_low_rating" => unanswered, "new_one_star" => new_one_star }
    rescue Date::Error
      invalid!("Use YYYY-MM-DD for week_ending.")
    end

    def self.count(value)
      number = Integer(value.to_s, 10, exception: false)
      invalid!("Review counts must be whole numbers from 0 to 1,000,000.") unless number&.between?(0, 1_000_000)

      number
    end

    def self.directory(row)
      host = row["directory"].to_s.strip.downcase.delete_prefix("www.")
      invalid!("Use directory hostnames, such as directory.example.") unless Site::HOST_FORMAT.match?(host)

      host
    end

    def self.citation(host, listings)
      tiers = listings.map { |row| row["tier"].to_s.strip }.uniq
      invalid!("Use one priority tier (1, 2, or 3) per directory.") unless tiers.one? && %w[1 2 3].include?(tiers.first)

      statuses = listings.map { |row| row["status"].to_s.strip }.uniq
      invalid!("Use listed, missing or unverified. Use one row for a missing or unverified directory.") unless
        statuses.one? && CITATION_STATUSES.include?(statuses.first) && (statuses.first == "listed" || listings.one?)

      record = { "directory" => host, "tier" => tiers.first.to_i, "issues" => [] }
      case statuses.first
      when "missing"
        record["issues"] << "missing_listing"
      when "unverified"
        record["unverified"] = true
      when "listed"
        keys = listings.map { |row| row["listing_key"].to_s.strip }
        invalid!("Give each listed record a distinct listing_key within its directory.") unless
          keys.all? { |key| key.match?(/\A[A-Za-z0-9_-]{1,100}\z/) } && keys.uniq.size == keys.size
        record["issues"] << "duplicate_listings" if listings.many?
        unverified_fields = CITATION_FIELDS.filter_map do |field|
          results = listings.map { |row| row["#{field}_match"].to_s.strip.downcase }
          invalid!("Use true, false or unknown for each listed name, address and phone match.") unless
            (results - %w[true false unknown]).empty?
          record["issues"] << "#{field}_mismatch" if results.include?("false")
          field if results.include?("unknown")
        end
        record["unverified_fields"] = unverified_fields if unverified_fields.any?
      end
      urls = listings.filter_map { |row| citation_url(host, row["listing_url"]) }.uniq
      record["listing_urls"] = urls if urls.any?
      record
    end

    def self.citation_url(host, value)
      text = value.to_s.strip
      return if text.empty?

      url = Tracking::ResultUrl.parse(text)
      unless text.bytesize <= 400 && !text.match?(/[\\[:cntrl:]]/) && url.is_a?(URI::HTTPS) && url.port == 443 &&
          Tracking::ResultUrl.host_matches?(host, url.host) && url.path.present? && url.path != "/" &&
          url.query.nil? && url.fragment.nil?
        invalid!("Use a public HTTPS listing link on the stated directory, without query strings or fragments.")
      end

      url.to_s
    end

    def self.invalid!(message)
      raise EvidenceImport::InvalidExport, message
    end
    private_class_method :review_week, :count, :directory, :citation, :citation_url, :invalid!
  end
end
