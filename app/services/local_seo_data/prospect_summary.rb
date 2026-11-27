module LocalSeoData
  module ProspectSummary
    METRICS = { "local_pack_position" => 1..100, "rating" => 1..5, "reviews_count" => 0..1_000_000,
      "profile_completeness" => 0..100, "review_velocity" => 0..10_000 }.freeze

    def self.build(data)
      summary = metrics(data, METRICS)
      summary["organic_positions"] = Array.wrap(data["organic_positions"]).first(5).grep(Hash).filter_map do |item|
        keyword = display_text(item["keyword"])
        rank = metric(item["rank"], 1..200)
        { "keyword" => keyword, "rank" => rank } if keyword && rank
      end
      summary["competitors"] = Array.wrap(data["competitors"]).first(3).grep(Hash).filter_map do |item|
        name = display_text(item["name"])
        values = metrics(item, METRICS.slice("rating", "reviews_count").merge("rank" => 1..100))
        values.merge("name" => name) if name
      end
      summary
    end

    def self.metrics(data, ranges)
      ranges.filter_map do |field, range|
        value = metric(data[field], range)
        [field, value] if value
      end.to_h
    end

    def self.metric(value, range)
      value if value.is_a?(Numeric) && range.cover?(value)
    end

    def self.display_text(value)
      return unless value.is_a?(String) && value.present? && value.length <= 120 &&
        !value.match?(/[<>[:cntrl:]]|[\w.+-]+@[\w.-]+\.[a-z]{2,}/i)

      value.squish
    end
    private_class_method :metrics, :metric, :display_text
  end
end
