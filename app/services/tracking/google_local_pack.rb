module Tracking
  module GoogleLocalPack
    KEY = "google_local_pack_v1"
    TOP = 3

    def self.read(items)
      pack = items.select { |item| item["type"] == "local_pack" && item["page"] == 1 && item["position"] == "left" }
      return { "coverage" => "unavailable", "listings" => [] } if pack.empty?

      candidates = pack.reject { |item| item["is_paid"] == true }
      ads = pack.select { |item| item["is_paid"] == true }.filter_map { |item| cid(item) }.to_set
      ranked = candidates.filter_map do |item|
        position = item["rank_absolute"]
        identity = cid(item)
        name = item["title"].to_s.squish
        next unless item["is_paid"] == false && position.is_a?(Integer) && position.positive? && identity && name.present?

        rating = item["rating"]
        reviews = rating["votes_count"] if rating.is_a?(Hash)
        score = rating["value"] if rating.is_a?(Hash) && rating["rating_type"] == "Max5" && rating["rating_max"] == 5
        [position, {
          "cid" => identity, "name" => name.first(120), "paid_seen" => ads.include?(identity),
          "reviews" => reviews.is_a?(Integer) && reviews >= 0 ? reviews : nil,
          "rating" => score.is_a?(Numeric) && score.between?(1, 5) ? score : nil
        }.compact]
      end.sort_by(&:first)
      # Only three fully identified, distinct rows establish a comparable pack.
      complete = candidates.size == TOP && ranked.size == TOP &&
        ranked.map(&:first).uniq.size == TOP && ranked.map { |_, row| row.fetch("cid") }.uniq.size == TOP
      listings = ranked.map(&:last).uniq { |row| row.fetch("cid") }.first(TOP)
      { "coverage" => complete ? "top_three" : "partial", "listings" => listings }
    end

    def self.cid(item)
      value = item["cid"]
      value if value.is_a?(String) && value.match?(/\A[1-9][0-9]{0,19}\z/) && value.to_i < 2**64
    end
    private_class_method :cid
  end
end
