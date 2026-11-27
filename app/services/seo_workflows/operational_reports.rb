module SeoWorkflows
  module OperationalReports
    private

    def maps_activity
      scans = LocalFalcon::MapsSummary.verified_scan_scope(@site).order(observed_on: :desc, id: :desc)
      scans.where(observed_on: @start..@day).limit(60).to_a.uniq { |scan| scan.keyword.downcase }.first(10).map do |scan|
        measure = LocalFalcon::MapsSummary.new(scan)
        grid = LocalFalcon::ScanGrid.new(scan)
        text = "#{scan.keyword} · #{scan.observed_on}."
        text += " Share of Local Voice: #{measure.share.round(2)}%." if measure.share
        measured = grid.points.count { |point| measured_rank?(point["rank"]) }
        if measured.positive?
          top_three = grid.points.count { |point| (1..3).cover?(point["rank"]) }
          text += " In the top three at #{top_three} of #{measured} measured pins."
        end
        prior = scans.where("LOWER(keyword) = ?", scan.keyword.downcase)
          .where(observed_on: (scan.observed_on - 35)...scan.observed_on).where.not(map_grid: nil).limit(20)
          .find { |candidate| grid.matches?(LocalFalcon::ScanGrid.new(candidate)) }
        if prior
          text += matched_pin_movement(grid, LocalFalcon::ScanGrid.new(prior), prior.observed_on)
        elsif grid.points.any?
          text += " This grid can serve as a baseline. Movement requires a matching grid."
        end
        row("Local Falcon · Google Maps", text, source_snapshot_path(scan))
      end
    end

    def matched_pin_movement(current, previous, date)
      baseline = previous.points.index_by { |point| point.values_at("lat", "lng") }
      transitions = current.points.filter_map do |point|
        before = baseline.fetch(point.values_at("lat", "lng")).fetch("rank")
        after = point.fetch("rank")
        next unless measured_rank?(before) && measured_rank?(after)

        ((1..3).cover?(after) ? 1 : 0) - ((1..3).cover?(before) ? 1 : 0)
      end
      return "" if transitions.empty?

      " Since #{date}, #{transitions.count(1)} gained and #{transitions.count(-1)} lost top-three placement across #{transitions.size} comparable pins."
    end

    def measured_rank?(rank)
      rank == "20+" || (rank.is_a?(Integer) && rank.positive?)
    end

    def review_activity
      # A single dated export provides comparison weeks, avoiding mixed feeds or overlapping imports.
      live = collected_evidence("M2")
      source = live || signal_scope("review_activity").where(
        "metrics->'records' @> CAST(? AS jsonb)", [{ "week_ending" => @day.iso8601 }].to_json
      ).first
      return [] unless source

      weeks = source.metrics.fetch("records").index_by { |record| record.fetch("week_ending") }
      current = weeks.fetch(@day.iso8601)
      baseline = (1..4).map { |offset| weeks[(@day - offset.weeks).iso8601] }
      return live_review_activity(live, current, baseline) if live

      count = current.fetch("new_reviews")
      text = "Week ending #{@day}: #{count} new reviews, #{current.fetch('unanswered_low_rating')} unanswered low-rated reviews " \
        "at week end and #{current.fetch('new_one_star')} new one-star reviews."
      text += " Average rating #{current.fetch('average_rating')} out of 5." if current["average_rating"]
      attention = current.fetch("new_one_star").positive? || current.fetch("unanswered_low_rating").positive?
      if baseline.all?
        average = baseline.sum { |week| week.fetch("new_reviews") } / 4.0
        text += " Previous four-week mean: #{average.round(2)} new reviews per week."
        if average.positive? && count < average * 0.6
          text += " Review volume fell by more than 40% against the previous four weeks."
          attention = true
        end
        if current["average_rating"] && baseline.last["average_rating"]
          text += " Average rating four weeks earlier: #{baseline.last.fetch('average_rating')} out of 5."
        end
      else
        text += " Four complete comparison weeks are required for the velocity alert."
      end

      [row("Weekly review activity", text, source_snapshot_path(source)).merge("attention" => attention)]
    end

    def saved_review_activity
      @site.source_snapshots.where(provider: [LocalSeoData::Collection::PROVIDER, LocalSeoData::DataForSeoCollection::PROVIDER])
        .where(observed_on: ..@now.in_time_zone(@site.time_zone).to_date)
        .where("metrics->>'host' = ? AND metrics->>'kind' = 'review_activity' AND metrics->>'state' = 'captured'", @site.host)
        .where("(metrics->>'period_on') BETWEEN ? AND ?", @start.iso8601, @day.iso8601)
        .order(Arel.sql("metrics->>'period_on' DESC"), id: :desc).limit(30)
        .uniq { |snapshot| snapshot.metrics["period_on"] }.filter_map do |snapshot|
          period = snapshot.metrics.fetch("period_on")
          sample = snapshot.metrics.fetch("records").find { |record| record["week_ending"] == period }
          next unless sample

          qualifier = sample["complete_coverage"] ? "new reviews" : "new reviews in the returned sample"
          description = "Week ending #{period}: #{sample.fetch('new_reviews')} #{qualifier}, " \
            "#{sample.fetch('new_one_star')} one-star and #{sample.fetch('unanswered_low_rating')} unanswered low-rated reviews at collection."
          row("#{snapshot.provider} · Google reviews", description, source_snapshot_path(snapshot))
        end
    end

    def live_review_activity(source, current, baseline)
      count = current.fetch("new_reviews")
      coverage = current["complete_coverage"] ? "#{count} new reviews" : "#{count} new reviews in the returned sample only"
      text = "Week ending #{@day}: #{coverage}, including #{current.fetch('new_one_star')} one-star reviews. " \
        "#{current.fetch('unanswered_low_rating')} of the sampled reviews rated 1 or 2 stars had no reply at collection."
      attention = current.fetch("new_one_star").positive? || current.fetch("unanswered_low_rating").positive?
      if current["complete_coverage"] && baseline.all? { |week| week && week["complete_coverage"] }
        average = baseline.sum { |week| week.fetch("new_reviews") } / 4.0
        text += " The previous four-week mean was #{average.round(2)}."
        if average.positive? && count < average * 0.6
          text += " Review volume fell by more than 40%."
          attention = true
        end
      else
        text += " Sample coverage was insufficient for a four-week velocity comparison."
      end

      [row("#{source.provider} · Google reviews", text, source_snapshot_path(source)).merge("attention" => attention)]
    end

    def collected_evidence(task)
      receipt = LocalSeoData::Collection.receipt(@site, task, @day)
      receipt if receipt && receipt.metrics["state"] == "captured" && receipt.metrics["host"] == @site.host
    end

    def citation_audit
      live = collected_evidence("E3")
      scope = signal_scope("citation_audit")
      current = live || scope.where(observed_on: @start..@day).first
      return [] unless current

      previous = if live
        @site.source_snapshots.where(provider: LocalSeoData::Collection::PROVIDER)
          .where("metrics->>'kind' = 'citation_audit' AND metrics->>'state' = 'captured' AND metrics->>'scope_digest' = ?",
            current.metrics.fetch("scope_digest"))
          .where("metrics->>'period_on' < ?", @day.iso8601).order(observed_on: :desc, id: :desc).first
      else
        scope.where(observed_on: ...current.observed_on).first
      end
      records = current.metrics.fetch("records")
      issue_count = records.count { |record| record.fetch("issues").present? }
      message = "#{records.size} directories checked in the supplied audit. #{issue_count} had citation issues."
      if live
        unverified = records.count { |record| !record["comparable"] }
        message += " Collected on #{current.observed_on}. #{current.metrics.fetch('directories_unavailable')} unavailable checks and #{unverified} unverified checks."
      else
        unverified = records.count { |record| record["unverified"] }
        partial = records.count { |record| record["unverified_fields"].present? }
        message += " #{unverified} unverified directories." if unverified.positive?
        message += " #{partial} directories had unverified fields." if partial.positive?
      end
      if previous
        prior = previous.metrics.fetch("records").index_by { |record| record.fetch("directory") }
        comparable = records.select do |record|
          candidate = prior[record.fetch("directory")]
          next false unless candidate

          live ? candidate["comparable"] && record["comparable"] : !candidate["unverified"] && !record["unverified"]
        end
        added, resolved = comparable.each_with_object([0, 0]) do |record, totals|
          baseline = prior.fetch(record.fetch("directory"))
          before = baseline.fetch("issues")
          after = record.fetch("issues")
          unchecked = citation_unchecked_issues(baseline) | citation_unchecked_issues(record)
          totals[0] += (after - before - unchecked).size
          totals[1] += (before - after - unchecked).size
        end
        message += " Across #{comparable.size} directories in both audits, #{added} new issues and #{resolved} resolved since #{previous.observed_on}."
      end
      path = source_snapshot_path(current)
      findings = records.select { |record| record.fetch("issues").present? }
        .sort_by { |record| [citation_priority(record), record.fetch("tier"), record.fetch("directory")] }
      header = row(live ? "Local SEO Data · Citation NAP audit" : "Citation NAP audit", message, path)
      header["attention"] = findings.any? { |record| citation_priority(record).zero? }
      [header] + findings.first(20).map do |record|
        issues = record.fetch("issues").map(&:humanize).join(", ")
        priority = %w[Critical Important Monitor].fetch(citation_priority(record))
        row(priority, "#{record.fetch('directory')} · #{issues}.", path)
      end
    end

    def citation_unchecked_issues(record)
      Array(record["unverified_fields"]).map { |field| "#{field}_mismatch" } - record.fetch("issues")
    end

    def citation_priority(record)
      issues = record.fetch("issues")
      return 0 if (issues & %w[address_mismatch phone_mismatch duplicate_listings]).any?

      record.fetch("tier") < 3 ? 1 : 2
    end
  end
end
