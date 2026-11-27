module LocalSeoData
  module DataForSeoReviews
    DEPTH = Reviews::LIMIT
    MAX_WAIT = 24.hours

    def self.collect(site, template, day)
      input = DataForSeoCollection.settings("M2")
      metrics = { "kind" => "review_activity", "host" => site.host, "period_on" => day.iso8601,
        "scope_digest" => scope(site, input), "state" => "collecting" }
      snapshot, reserved = DataForSeoCollection.reserve(site, template, day, metrics)
      return unless snapshot
      return if snapshot.provider != DataForSeoCollection::PROVIDER
      unless reserved
        return if snapshot.metrics["state"].in?(%w[captured unconfirmed])

        return :pending
      end

      id = Tracking::DataForSeo.new.submit_reviews(**input, depth: DEPTH, tag: tag(snapshot))
      snapshot.update!(metrics: metrics.merge("state" => "submitted", "task_id" => id))
      :pending
    rescue Tracking::DataForSeo::Unavailable
      snapshot.update!(metrics: metrics.merge("state" => "unconfirmed"))
      nil
    end

    def self.poll_pending
      SourceSnapshot.where(provider: DataForSeoCollection::PROVIDER)
        .where("metrics->>'kind' = 'review_activity' AND metrics->>'state' IN ('collecting', 'submitted')")
        .find_each { |snapshot| poll(snapshot) }
    end

    def self.poll(snapshot)
      snapshot.with_lock do
        site = snapshot.site.reload
        input = DataForSeoCollection.settings("M2")
        metrics = snapshot.metrics
        state = metrics["state"]
        next unless state.in?(%w[collecting submitted])
        day = Date.iso8601(metrics.fetch("period_on"))
        expired = snapshot.created_at <= MAX_WAIT.ago
        if expired
          snapshot.update!(metrics: metrics.except("task_id").merge("state" => "unconfirmed"))
        end
        next if metrics["host"] != site.host
        if !expired && state == "submitted" && DataForSeoCollection.enabled?(site, "M2") &&
            metrics["scope_digest"] == scope(site, input)
          poll_submitted(snapshot, site, day, input)
        end
        SeoWorkflowRun.generate!(site: site, template: SeoWorkflows::Catalogue.fetch("M2"), day: day)
      end
    end

    def self.poll_submitted(snapshot, site, day, input)
      metrics = snapshot.metrics
      result = Tracking::DataForSeo.new.poll_reviews(id: metrics.fetch("task_id"), **input, depth: DEPTH, tag: tag(snapshot))
      return unless result

      summary = summarize(result, site: site, day: day, place_id: input.fetch(:place_id))
      snapshot.update!(metrics: metrics.except("task_id").merge(summary).merge("state" => "captured"))
    rescue Tracking::DataForSeo::Rejected, Client::Unavailable
      snapshot.update!(metrics: metrics.except("task_id").merge("state" => "unconfirmed"))
    rescue Tracking::DataForSeo::Unavailable
      nil
    end

    def self.summarize(result, site:, day:, place_id:)
      items, count, total = result.values_at("items", "items_count", "reviews_count")
      items = [] if items.nil? && count == 0 && total == 0
      raise Client::Unavailable unless items.is_a?(Array) && items.length == count && count <= DEPTH

      reviews = items.map do |item|
        raise Client::Unavailable unless item.is_a?(Hash) && item["type"] == "google_reviews_search" &&
          item["review_id"].is_a?(String) && item["review_id"].present? && item.key?("owner_answer")

        rating = item["rating"]
        raise Client::Unavailable unless rating.is_a?(Hash) && rating["rating_type"] == "Max5"

        { "date" => item["timestamp"], "rating" => rating["value"], "review_ref" => item["review_id"],
          "owner_reply" => item.values_at("owner_answer", "original_owner_answer", "owner_timestamp").any?(&:present?) ? "present" : nil }
      end
      raise Client::Unavailable unless reviews.uniq { |review| review["review_ref"] }.size == reviews.size

      data = { "place_id" => place_id, "total_reviews" => total, "reviews" => reviews }
      Reviews.summarize(data, day: day, zone: site.time_zone, place_id: place_id)
    end

    def self.scope(site, input)
      Digest::SHA256.hexdigest([site.host, input, DEPTH, "en", "newest"].to_json)
    end

    def self.tag(snapshot) = "searchdesk-m2-#{snapshot.id}"

    private_class_method :poll_submitted, :summarize, :scope, :tag
  end
end
