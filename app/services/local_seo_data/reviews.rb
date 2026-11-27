require "time"

module LocalSeoData
  module Reviews
    LIMIT = 100

    def self.summarize(data, day:, zone:, place_id:)
      reviews, total = data.values_at("reviews", "total_reviews")
      raise Client::Unavailable unless reviews.is_a?(Array) && reviews.size <= LIMIT &&
        total.is_a?(Integer) && total >= reviews.size && (data["place_id"].nil? || data["place_id"] == place_id)
      raise Client::Unavailable if reviews.empty? && total.positive?

      dated = reviews.map do |item|
        raise Client::Unavailable unless item.is_a?(Hash) && item["rating"].is_a?(Integer) &&
          (1..5).cover?(item["rating"]) && item.key?("owner_reply") &&
          (item["owner_reply"].nil? || item["owner_reply"].is_a?(String)) &&
          item["date"].to_s.match?(/(?:Z|[+-]\d\d:\d\d)\z/)

        posted = Time.iso8601(item.fetch("date").sub(" ", "T").delete(" "))
        [posted.in_time_zone(zone).to_date, item.fetch("rating"), item["owner_reply"].nil?]
      end
      raise Client::Unavailable unless dated.each_cons(2).all? { |first, second| first.first >= second.first }

      unique_sample = reviews.uniq.size == reviews.size
      all_returned = total == reviews.size && unique_sample
      oldest = dated.last&.first
      records = (0..4).map do |offset|
        week = day - offset * 7
        first_day = week - 6
        observed = dated.select { |date, _, _| date.between?(first_day, week) }
        count = observed.size
        { "week_ending" => week.iso8601, "new_reviews" => count,
          "complete_coverage" => all_returned || (oldest.present? && oldest < first_day && unique_sample),
          "average_rating" => count.positive? ? (observed.sum { |_, rating, _| rating }.to_f / count).round(2) : nil,
          "unanswered_low_rating" => observed.count { |_, rating, unanswered| rating <= 2 && unanswered },
          "new_one_star" => observed.count { |_, rating, _| rating == 1 } }
      end
      { "records" => records, "reviews_sampled" => reviews.size, "reviews_reported" => total }
    rescue ArgumentError
      raise Client::Unavailable
    end
  end
end
