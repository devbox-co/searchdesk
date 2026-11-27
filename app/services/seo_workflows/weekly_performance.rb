module SeoWorkflows
  class WeeklyPerformance
    include Rails.application.routes.url_helpers

    def initialize(site:, day:, now:)
      @site, @day, @now = site, day, now
      first_day = day.beginning_of_week
      @current = first_day..day
      @prior = (first_day - 7)..(day - 7)
    end

    def row(has_saved_evidence:)
      organic = organic_rankings
      maps = maps_visibility
      pack = local_pack
      reviews = review_activity
      return if !has_saved_evidence && organic["current_series"].zero? && [maps, pack, reviews].all?(&:empty?)

      comparable_map = %w[share average_rank].any? { |metric| maps.dig("current", metric) && maps.dig("previous", metric) }
      complete = organic.fetch("pairs").positive? && comparable_map && pack.key?("previous") && reviews.key?("previous")
      finding, action, urgent = next_step(organic, maps, pack, reviews)
      counts = organic.fetch("counts")
      status = if organic.fetch("pairs").zero?
        "A week-over-week organic ranking change could not be measured."
      else
        direction = if counts.fetch("improved") > counts.fetch("declined")
          "improved overall"
        elsif counts.fetch("declined") > counts.fetch("improved")
          "declined overall"
        elsif counts.fetch("improved").positive?
          "were mixed"
        elsif counts.fetch("steady").positive?
          "held steady"
        else
          "remained outside the tracked results"
        end
        "Organic rankings #{direction} across #{organic.fetch('pairs')} comparable keyword and device pairs."
      end
      status = "Simulated data. #{status}" if @site.tracking_mode == "demo"
      summary = {
        "start" => @current.begin.iso8601, "end" => @day.iso8601,
        "previous_start" => @prior.begin.iso8601, "previous_end" => @prior.end.iso8601,
        "coverage" => complete ? "complete" : "partial", "status" => status, "closed_week" => closed_week?,
        "organic" => organic, "maps" => maps, "local_pack" => pack, "reviews" => reviews,
        "finding" => finding, "next_action" => action
      }
      { "source" => "Weekly performance summary", "text" => "#{status} #{finding}", "attention" => urgent,
        "weekly_performance" => summary }
    end

    private

    def organic_rankings
      source = @site.tracking_mode
      observations = RankObservation.joins(daily_slot: { tracking_series: :keyword }).merge(TrackingSeries.current)
        .where(keywords: { site_id: @site.id }, tracking_series: { source: source }, rank_observations: { source: source },
          daily_slots: { day: @prior.begin..@day }).where("tracking_series.settings->>'host' = ?", @site.host)
        .comparable.where("rank_observations.status = 'outside' OR rank_observations.position > 0")
        .order("daily_slots.day DESC", "rank_observations.id DESC")
        .pluck("tracking_series.id", "keywords.id", "keywords.phrase", "tracking_series.device",
          "daily_slots.day", "rank_observations.position", "rank_observations.status", "tracking_series.settings")
        .group_by(&:first)
      current_count = 0
      changes = observations.values.filter_map do |series|
        current = series.find { |record| @current.cover?(record[4]) }
        next unless current

        current_count += 1
        previous = series.find { |record| @prior.cover?(record[4]) }
        next unless previous

        _, keyword_id, term, device, date, position, state, settings = current
        old_state, old_position = previous.values_at(6, 5)
        direction = if state == "outside"
          old_state == "outside" ? "outside" : "declined"
        elsif old_state == "outside" || position < old_position
          "improved"
        elsif position > old_position
          "declined"
        else
          "steady"
        end
        { "term" => term, "device" => device, "direction" => direction, "market" => settings["location"],
          "current" => { "date" => date.iso8601, "position" => position, "status" => state },
          "previous" => { "date" => previous[4].iso8601, "position" => old_position, "status" => old_state },
          "source_path" => keyword_path(keyword_id, device: device) }
      end
      counts = %w[improved declined steady outside].index_with { |direction| changes.count { |item| item.fetch("direction") == direction } }
      biggest_decline = changes.select { |item| item["direction"] == "declined" }.max_by do |item|
        current, previous = item.values_at("current", "previous")
        [current["status"] == "outside" ? 1 : 0, current["position"].to_i - previous["position"].to_i]
      end
      displayed = ([biggest_decline].compact + changes.reject { |item| item["direction"] == "outside" }).uniq.first(8)
      { "pairs" => changes.size, "current_series" => current_count, "counts" => counts, "changes" => displayed }
    end

    def maps_visibility
      scans = LocalFalcon::MapsSummary.verified_scan_scope(@site).order(observed_on: :desc, id: :desc)
      current = scans.where(observed_on: @current).limit(30).find do |scan|
        summary = LocalFalcon::MapsSummary.new(scan)
        summary.share || summary.average_rank
      end
      return {} unless current

      grid = LocalFalcon::ScanGrid.new(current)
      prior = scans.where(observed_on: @prior).where("LOWER(keyword) = ?", current.keyword.downcase)
        .where.not(map_grid: nil).limit(30).find { |scan| grid.matches?(LocalFalcon::ScanGrid.new(scan)) }
      result = { "keyword" => current.keyword, "current" => scan_reading(current) }
      result["previous"] = scan_reading(prior) if prior
      result
    end

    def scan_reading(snapshot)
      reading = LocalFalcon::MapsSummary.new(snapshot)
      { "date" => snapshot.observed_on.iso8601, "share" => reading.share, "average_rank" => reading.average_rank,
        "source_path" => source_snapshot_path(snapshot) }
    end

    def local_pack
      cid = Tracking::GooglePlacement.profile_for(@site)&.cid
      return {} unless cid.to_s.match?(/\A[1-9][0-9]{0,19}\z/)

      latest = CompetitorPacks.latest_samples(@site, @current).limit(20)
        .select { |sample| complete_pack?(sample) }
      return {} if latest.empty?

      prior = CompetitorPacks.latest_samples(@site, @prior).where(tracking_series: { id: latest.map(&:pack_series_id) })
        .select { |sample| complete_pack?(sample) }.index_by(&:pack_series_id)
      current = latest.find { |sample| prior.key?(sample.pack_series_id) } || latest.first
      result = { "keyword" => current.pack_keyword, "market" => current.pack_market, "device" => current.pack_device,
        "current" => pack_reading(current, cid.to_s) }
      result["previous"] = pack_reading(prior.fetch(current.pack_series_id), cid.to_s) if prior.key?(current.pack_series_id)
      result
    end

    def complete_pack?(sample)
      sample.evidence.dig(Tracking::GoogleLocalPack::KEY, "coverage") == "top_three"
    end

    def pack_reading(sample, cid)
      listings = sample.evidence.fetch(Tracking::GoogleLocalPack::KEY).fetch("listings")
      index = listings.index { |record| record["cid"] == cid }
      { "date" => sample.pack_day.to_s, "position" => index && index + 1, "rating" => index && listings[index]["rating"],
        "source_path" => competitor_capture_seo_workflows_path(capture_id: sample.id) }
    end

    def closed_week?
      @day.sunday? && @day < @now.in_time_zone(@site.time_zone).to_date
    end

    def review_activity
      return {} unless closed_week?

      date = @day.iso8601
      previous_date = @prior.end.iso8601
      feeds = WeeklyReviewEvidence.new(site: @site, start: @prior.begin, day: @day, now: @now).feeds
      feed = feeds.select { |candidate| candidate.key?(date) }.max_by { |candidate| candidate.key?(previous_date) ? 1 : 0 }
      return {} unless feed

      result = { "current" => review_reading(date, feed.fetch(date)) }
      result["previous"] = review_reading(previous_date, feed.fetch(previous_date)) if feed.key?(previous_date)
      result
    end

    def review_reading(date, week)
      week.slice("new_reviews", "average_rating", "unanswered_low_rating", "new_one_star")
        .merge("date" => date, "source_path" => source_snapshot_path(week.fetch("snapshot_id")))
    end

    def next_step(organic, maps, pack, reviews)
      if (week = reviews["current"]) && week.fetch("unanswered_low_rating").positive?
        return recommendation("Unanswered low-rated Google reviews need attention.",
          "Review the unanswered low-rated Google reviews in M2 and prepare replies for owner approval.", week.fetch("source_path"), true)
      end
      if week && week.fetch("new_one_star").positive?
        return recommendation("A new one-star Google review was observed.",
          "Read the new one-star review in Google and check whether it needs a follow-up.", week.fetch("source_path"), true)
      end
      if pack.dig("previous", "position") && pack.dig("current", "position").nil?
        return recommendation("The business left the top three in the sampled Google Maps results for “#{pack.fetch('keyword')}”.",
          "Inspect the latest Maps results for this search and compare the listings now in the top three.",
          pack.fetch("current").fetch("source_path"), true)
      end
      if (decline = organic.fetch("changes").find { |change| change["direction"] == "declined" })
        return recommendation("The organic result for “#{decline.fetch('term')}” fell on #{decline.fetch('device')}.",
          "Check which page Google shows for “#{decline.fetch('term')}” on #{decline.fetch('device')} and confirm it matches your selected page.",
          decline.fetch("source_path"))
      end
      share, previous_share = [maps.dig("current", "share"), maps.dig("previous", "share")]
      if share && previous_share && share < previous_share
        return recommendation("Top-three coverage declined on the same Maps grid.",
          "Open the latest Maps grid and check which areas lost top-three positions.", maps.fetch("current").fetch("source_path"))
      end
      previous_count = reviews.dig("previous", "new_reviews")
      if previous_count&.positive? && week.fetch("new_reviews") < previous_count * 0.6
        return recommendation("New Google reviews fell by more than 40% compared with the previous week.",
          "Check whether this week’s review requests reached customers.", week.fetch("source_path"))
      end
      if !closed_week? && organic.fetch("pairs").zero? && organic.fetch("current_series").positive?
        return recommendation("Ranking readings are available this week, but the same weekdays last week lack comparable readings.",
          "Keep tracking the same keywords and devices next week to establish a comparison.", rankings_path(source: "local", day: @day))
      end
      if closed_week? && !reviews.key?("previous")
        return recommendation("Comparable review coverage is missing for one or both weeks.",
          "Collect comparable Google review evidence for the two reporting weeks in M2.", setup_seo_workflows_path(anchor: "M2"))
      end
      if maps.empty?
        return recommendation("No verified Maps grid was available for this week.",
          "Save a baseline Google Maps grid for a priority search term.", local_falcon_connection_path(anchor: "maps-scans"))
      end
      unless maps.key?("previous")
        return recommendation("The saved Maps grid has no matching reading from last week.",
          "Repeat the current Maps scan next week using the same search and pin locations.", maps.fetch("current").fetch("source_path"))
      end
      if (gain = organic.fetch("changes").find { |change| change["direction"] == "improved" })
        return recommendation("The organic result for “#{gain.fetch('term')}” improved on #{gain.fetch('device')}.",
          "Repeat the same search next week to confirm whether the gain holds.", gain.fetch("source_path"))
      end
      recommendation("The saved comparisons show no urgent issue in the weekly checks.",
        "Repeat the same ranking checks next week to confirm whether the movement holds.", rankings_path(source: "local", day: @day))
    end

    def recommendation(finding, action, path, urgent = false)
      [finding, { "text" => action, "source_path" => path }, urgent]
    end
  end
end
