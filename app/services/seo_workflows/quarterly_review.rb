module SeoWorkflows
  class QuarterlyReview
    include Rails.application.routes.url_helpers

    DAYS = 90
    GRID_BASELINE_TOLERANCE = 14

    def initialize(site:, day:, now:)
      @site, @day, @now = site, day, now
      @window = (day - (DAYS - 1))..day
    end

    def row(competitors:, ai_evidence:, has_saved_evidence:)
      rankings = organic_trends
      maps = map_comparison
      reviews = review_trend
      ai = ai_trends
      return if !has_saved_evidence && rankings.empty? && maps.empty? && reviews.fetch("weeks").none? { |week| week["source_path"] } &&
        competitors.empty? && ai.empty? && ai_evidence.empty?

      movements = rankings.group_by { |item| item.fetch("change") <=> 0 }
      improved = movements.fetch(1, [])
      declined = movements.fetch(-1, [])
      steady = movements.fetch(0, [])
      priorities = priorities_for(declined.first, maps, reviews, competitors, ai)
      review = {
        "start" => @window.begin.iso8601, "end" => @day.iso8601,
        "ranking_counts" => { "improved" => improved.size, "declined" => declined.size, "steady" => steady.size },
        "rankings" => (improved.first(4) + declined.first(4) + steady.first(2)),
        "maps" => maps, "reviews" => reviews, "ai_trends" => ai,
        "competitors" => competitors, "ai_evidence" => ai_evidence, "priorities" => priorities
      }
      organic = rankings.empty? ? "No comparable organic ranking pairs were available." :
        "#{improved.size} organic keyword and device pairs improved, #{declined.size} declined, and #{steady.size} held steady."
      organic = "Simulated data. #{organic}" if @site.tracking_mode == "demo"
      summary = [organic]
      summary << movement_text(improved.first) if improved.any?
      summary << movement_text(declined.first) if declined.any?
      summary << priorities.first.fetch("action")
      review["summary"] = summary
      review["winning_notes"] = improved.first(2).map { |item| movement_text(item) }
      review["issue_notes"] = declined.first(2).map { |item| movement_text(item) }
      if (pin_changes = maps["pin_changes"])
        review["winning_notes"] << "#{pin_changes['improved']} comparable Maps pins improved." if pin_changes.fetch("improved", 0).positive?
        review["issue_notes"] << "#{pin_changes['declined']} comparable Maps pins declined." if pin_changes.fetch("declined", 0).positive?
      end
      if reviews.fetch("unanswered").positive?
        review["issue_notes"] << "#{reviews.fetch('unanswered')} low-rated reviews were unanswered in the covered weeks."
      end
      { "source" => "90-day quarterly review", "text" => summary.join(" "), "quarterly_review" => review }
    end

    private

    def organic_trends
      source = @site.tracking_mode
      scope = RankObservation.joins(daily_slot: { tracking_series: :keyword }).merge(TrackingSeries.current)
        .where(keywords: { site_id: @site.id }, tracking_series: { source: source }, rank_observations: { source: source, status: "ranked" },
          daily_slots: { day: @window }).where("tracking_series.settings->>'host' = ?", @site.host).where.not(position: nil)
      scope.order("daily_slots.day", "rank_observations.id")
        .pluck("tracking_series.id", "keywords.id", "keywords.phrase", "tracking_series.device", "daily_slots.day", "rank_observations.position")
        .group_by(&:first).values.filter_map do |series|
          next if series.size < 2
          _, keyword_id, term, device, first_day, first_rank = series.first
          _, _, _, _, last_day, last_rank = series.last
          next if first_day == last_day

          { "term" => term, "device" => device, "first_on" => first_day.iso8601, "last_on" => last_day.iso8601,
            "first" => first_rank, "last" => last_rank, "change" => first_rank - last_rank,
            "source_path" => keyword_path(keyword_id, device: device) }
        end.sort_by { |item| [-item.fetch("change").abs, item.fetch("term"), item.fetch("device")] }
    end

    def movement_text(item)
      "#{item.fetch('term')} on #{item.fetch('device')} moved from position #{item.fetch('first')} to #{item.fetch('last')} " \
        "between #{item.fetch('first_on')} and #{item.fetch('last_on')}."
    end

    def map_comparison
      scans = LocalFalcon::MapsSummary.verified_scan_scope(@site).order(observed_on: :desc, id: :desc)
      latest = scans.where(observed_on: @window).first
      return {} unless latest

      current_grid = LocalFalcon::ScanGrid.new(latest)
      candidates = scans.where(observed_on: (@window.begin - GRID_BASELINE_TOLERANCE)...latest.observed_on)
        .where("LOWER(keyword) = ?", latest.keyword.downcase).where.not(map_grid: nil).limit(160)
      baseline = candidates.select { |scan| current_grid.matches?(LocalFalcon::ScanGrid.new(scan)) }
        .min_by { |scan| (scan.observed_on - @window.begin).abs }
      current = grid_summary(latest, current_grid)
      return { "keyword" => latest.keyword, "current" => current } unless baseline

      earlier_grid = LocalFalcon::ScanGrid.new(baseline)
      before = earlier_grid.points.index_by { |point| point.values_at("lat", "lng") }
      changes = current_grid.points.filter_map do |point|
        old = before.fetch(point.values_at("lat", "lng")).fetch("rank")
        new = point.fetch("rank")
        next unless old && new

        next "unchanged" if old == new
        next "improved" if new != "20+" && (old == "20+" || new < old)
        "declined"
      end.tally
      { "keyword" => latest.keyword, "current" => current, "baseline" => grid_summary(baseline, earlier_grid),
        "baseline_near_start" => (baseline.observed_on - @window.begin).abs <= GRID_BASELINE_TOLERANCE,
        "pin_changes" => changes }
    end

    def grid_summary(scan, grid)
      measurement = LocalFalcon::MapsSummary.new(scan)
      { "date" => scan.observed_on.iso8601, "arp" => measurement.average_rank, "solv" => measurement.share,
        "source_path" => source_snapshot_path(scan), "size" => measurement.grid_size,
        "pins" => grid.mapped_points.map { |pin| pin.slice("x", "y", "rank") } }
    end

    def review_trend
      days = WeeklyReviewEvidence.full_weeks(@window)
      feeds = WeeklyReviewEvidence.new(site: @site, start: @window.begin, day: @day, now: @now).feeds
      feed = feeds.max_by { |candidate| (days & candidate.keys).size } || {}
      weeks = days.map do |day|
        record = feed[day]
        if record
          record.slice("new_reviews", "average_rating", "unanswered_low_rating", "new_one_star")
            .merge("week_ending" => day, "source_path" => source_snapshot_path(record.fetch("snapshot_id")))
        else
          { "week_ending" => day }
        end
      end
      result = { "weeks" => weeks, "covered" => (days & feed.keys).size,
        "new_reviews" => weeks.sum { |week| week.fetch("new_reviews", 0) },
        "unanswered" => weeks.sum { |week| week.fetch("unanswered_low_rating", 0) } }
      if weeks.size >= 8
        early, late = [weeks.first(4), weeks.last(4)]
        if (early + late).all? { |week| week.key?("new_reviews") }
          result["first_four_reviews"] = early.sum { |week| week.fetch("new_reviews") }
          result["last_four_reviews"] = late.sum { |week| week.fetch("new_reviews") }
        end
      end
      result
    end

    def ai_trends
      @site.source_snapshots.where(provider: AiVisibilitySample::PROVIDER, observed_on: @window)
        .where("metrics->>'host' = ? AND metrics->>'status' = 'captured'", @site.host)
        .where("jsonb_typeof(metrics->'site_cited') = 'boolean'").order(observed_on: :desc, id: :desc).limit(120)
        .group_by { |sample| sample.metrics.values_at("engine", "model", "prompt_digest", "country", "location_code", "device") }
        .filter_map do |(engine, model, prompt, country, _, _), samples|
          next if engine.blank? || model.blank? || prompt.blank? || country.blank?
          current, baseline = samples.first, samples.last
          next unless baseline.observed_on < current.observed_on

          { "engine" => AiVisibilitySample::LABELS.fetch(engine, engine), "model" => model,
            "market" => current.metrics["location"] || country,
            "first_on" => baseline.observed_on.iso8601, "last_on" => current.observed_on.iso8601,
            "first_cited" => baseline.metrics.fetch("site_cited"), "last_cited" => current.metrics.fetch("site_cited"),
            "source_path" => source_snapshot_path(current), "comparison_path" => source_snapshot_path(baseline) }
        end.first(10)
    end

    def priorities_for(decline, maps, reviews, competitors, ai)
      priorities = []
      if reviews.fetch("unanswered").positive?
        source = reviews.fetch("weeks").reverse.find { |week| week.fetch("unanswered_low_rating", 0).positive? }
        priorities << priority("Review the unanswered low-rated Google reviews and prepare replies for approval.",
          "Track unanswered low-rated reviews in the next M2 report.", source.fetch("source_path"))
      end
      if decline
        priorities << priority("Review the page assigned to “#{decline.fetch('term')}” and inspect the #{decline.fetch('device')} results for that search.",
          "Compare the next reading on the same device and market with position #{decline.fetch('last')}.", decline.fetch("source_path"))
      end
      if maps["baseline"]
        focus = maps.fetch("pin_changes").fetch("declined", 0).positive? ? " and inspect the pins that lost rank" : ""
        priorities << priority("Repeat the matching Google Maps grid for “#{maps.fetch('keyword')}”#{focus}.",
          "Compare top-three coverage and pin movement on the same grid.", maps.fetch("current").fetch("source_path"))
      else
        priorities << priority("Save comparable Google Maps grids at the start and end of the next quarter.",
          "Use the same keyword, location and pin coordinates to establish a baseline.", local_falcon_connection_path(anchor: "maps-scans"))
      end
      if competitors.any?
        priorities << priority("Recheck the local pack sample for the same query, market and device.",
          "Compare two complete packs to confirm which listings entered or left the top three.", competitors.first.fetch("path"))
      end
      if reviews.fetch("covered") < reviews.fetch("weeks").size && priorities.size < 5
        priorities << priority("Complete a weekly review record for each full week next quarter.",
          "Use comparable weekly coverage to judge changes in new reviews and rating.", setup_seo_workflows_path(anchor: "M2"))
      end
      if priorities.size < 3 && reviews.fetch("unanswered").zero? && reviews.fetch("covered").positive? &&
          reviews.fetch("covered") == reviews.fetch("weeks").size
        source = reviews.fetch("weeks").last.fetch("source_path")
        priorities << priority("Keep the weekly Google review checks running next quarter.",
          "Track the weekly review count, average rating and unanswered low-rated reviews.", source)
      end
      if priorities.size < 5
        priorities << priority("Repeat the approved AI visibility question in the same engine and market.",
          "Compare usable citations for the same question and model.", ai.first&.fetch("source_path") || setup_seo_workflows_path(anchor: "M5"))
      end
      priorities.first(5)
    end

    def priority(action, measure, path)
      { "action" => action, "measure" => measure, "source_path" => path }
    end
  end
end
