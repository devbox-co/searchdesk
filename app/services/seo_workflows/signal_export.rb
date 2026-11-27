module SeoWorkflows
  # These contracts describe evidence supplied by the workspace owner. Each row
  # is scoped to this export date, and free text is used only to build a draft.
  module SignalExport
    TYPES = {
      "profile_fields" => "Business Profile fields",
      "lsa_rankings" => "Local Services Ads positions",
      "ai_visibility" => "AI search observations",
      "post_brief" => "Business Profile post brief",
      "review_queue" => "Unanswered review ratings",
      "prospect" => "Prospect evidence",
      "competitors" => "Competitor market observations"
    }.freeze
    PROFILE_FIELDS = %w[name category hours website services].freeze
    ENGINES = %w[google_ai_overviews chatgpt gemini perplexity].freeze
    PROSPECT_CHECKS = %w[website business_profile rankings citations reviews].freeze

    IDENTITIES = {
      "profile_fields" => %w[field], "lsa_rankings" => %w[query market],
      "ai_visibility" => %w[engine prompt market], "review_queue" => %w[review_ref],
      "prospect" => %w[target_host check], "competitors" => %w[business query market]
    }.freeze

    def self.summarize(kind, rows)
      records = rows.map do |row|
        case kind
        when "profile_fields"
          { "field" => choice(row, "field", PROFILE_FIELDS), "value" => public_text(row, "value") }
        when "lsa_rankings"
          { "query" => public_text(row, "query"), "market" => public_text(row, "market"),
            "position" => integer(row, "position", 1..100) }
        when "ai_visibility"
          { "engine" => choice(row, "engine", ENGINES), "prompt" => public_text(row, "prompt"),
            "market" => public_text(row, "market"), "mentioned" => boolean(row, "mentioned"),
            "cited" => boolean(row, "cited") }
        when "post_brief"
          { "service" => public_text(row, "service"), "approved_detail" => public_text(row, "approved_detail") }
        when "review_queue"
          # Only a local export reference and rating belong in the draft.
          { "review_ref" => reference(row, "review_ref"), "rating" => integer(row, "rating", 1..5) }
        when "prospect"
          host = public_text(row, "target_host").downcase
          invalid!("target_host") unless host.match?(/\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,63}\z/) && !host.include?("..")
          { "target_host" => host, "check" => choice(row, "check", PROSPECT_CHECKS),
            "observation" => public_text(row, "observation") }
        when "competitors"
          { "business" => public_text(row, "business"), "query" => public_text(row, "query"),
            "market" => public_text(row, "market"), "map_position" => integer(row, "map_position", 1..100),
            "review_count" => integer(row, "review_count", 0..1_000_000), "active_ad" => boolean(row, "active_ad") }
        end
      end
      fields = IDENTITIES[kind]
      keys = fields ? records.map { |record| record.values_at(*fields) } : records
      invalid!("duplicate rows") unless keys.uniq == keys
      { "records" => records }
    end

    def self.public_text(row, key)
      value = row[key].to_s.squish
      invalid!(key) if value.empty? || value.length > 220 ||
        value.match?(/\b[\w.+-]+@[\w.-]+\.[a-z]{2,}\b|\b(?:sk-proj-|sk-ant-|bearer\s+)\S+/i)

      value
    end

    def self.choice(row, key, options)
      value = row[key].to_s.strip
      invalid!(key) unless options.include?(value)
      value
    end

    def self.integer(row, key, range)
      value = Integer(row[key].to_s.strip, exception: false)
      invalid!(key) unless range.cover?(value)
      value
    end

    def self.boolean(row, key)
      choice(row, key, %w[true false]) == "true"
    end

    def self.reference(row, key)
      value = row[key].to_s.strip
      invalid!(key) unless value.match?(/\A[A-Za-z0-9_-]{1,160}\z/)
      value
    end

    def self.invalid!(field)
      raise EvidenceImport::InvalidExport, "Check the required value for #{field.humanize.downcase}."
    end
    private_class_method :public_text, :choice, :integer, :boolean, :reference, :invalid!
  end
end
