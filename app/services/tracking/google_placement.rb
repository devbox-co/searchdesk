module Tracking
  class GooglePlacement
    METHOD = "google_absolute_v1"
    KEY = "google_placement"
    Profile = Data.define(:place_id, :name, :cid)

    def self.profile_for(site)
      connection = site.local_falcon_connection
      return unless connection&.place_id.present? && connection.verified_name.present? && connection.synced_at

      Profile.new(connection.place_id, connection.verified_name, connection.result["google_cid"])
    end

    def self.read(items:, organic:, depth:, profile:)
      covered = organic.fetch(:coverage)
      winner = organic[:position]
      return unless winner || covered == depth

      organic_items = items.select { |item| item["type"] == "organic" }
        .index_by { |item| positive_rank(item["rank_group"]) }
      ranks = (1..(winner || covered)).map { |rank| positive_rank(organic_items.fetch(rank)["rank_absolute"]) }
      return if ranks.any?(&:nil?) || ranks.each_cons(2).any? { |earlier, later| earlier >= later }

      # The boundary is the last organic result we needed to verify. Results
      # below it cannot improve a winner or establish visibility in the sample.
      pack = items.select { |item| item["type"] == "local_pack" && item["is_paid"] != true && item["position"] != "right" }
      matched = matching_pack(pack, profile)
      return if matched.any? { |item| !positive_rank(item["rank_absolute"]) }
      listing = matched.select { |item| positive_rank(item["rank_absolute"]) < ranks.last }
        .min_by { |item| positive_rank(item["rank_absolute"]) }

      scope = { "method" => METHOD, "place_id" => profile&.place_id, "profile_cid" => profile&.cid }.compact
      if listing
        scope.merge("status" => "ranked", "position" => positive_rank(listing["rank_absolute"]),
          "type" => "local_pack", "profile_name" => profile.name)
      elsif winner
        scope.merge("status" => "ranked", "position" => ranks.last, "type" => "organic", "url" => organic.fetch(:winning_url))
      else
        scope.merge("status" => "outside")
      end
    end

    def self.positive_rank(value)
      rank = Integer(value.to_s, 10, exception: false)
      rank if rank&.between?(1, 10_000)
    end
    private_class_method :positive_rank

    def self.matching_pack(items, profile)
      return [] unless profile

      items.select do |item|
        if item["place_id"].present?
          item["place_id"] == profile.place_id
        else
          profile.cid.present? && item["cid"].to_s == profile.cid
        end
      end
    end
    private_class_method :matching_pack
  end
end
