module CompetingPages
  module ArticleComparison
    FIELDS = %w[title description].freeze

    def self.fields(google, page)
      FIELDS.index_with do |field|
        shown = google[field].to_s.squish
        original = page[field].to_s.squish
        next "not_comparable" if original.blank? || shown.blank? || page["status"] != "observed"
        next "matches" if shown == original
        prefix = visible_prefix(shown)
        next "truncated" if prefix && original.start_with?(prefix) && original.length > prefix.length
        "different"
      end
    end

    def self.visible_prefix(text)
      return unless text.match?(/(?:\.{3}|…)\z/)
      text.sub(/\s*(?:\.{3}|…)\z/, "").strip.presence
    end
  end
end
