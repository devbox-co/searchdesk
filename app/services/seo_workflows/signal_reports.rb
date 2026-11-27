module SeoWorkflows
  module SignalReports
    private

    def profile_changes
      imported = compare_signals("profile_fields", "Business Profile", %w[field]) do |before, after|
        "Changed from #{before.fetch('value')} to #{after.fetch('value')}."
      end
      ProfileMonitor.new(@site, @day).rows + imported
    end

    def lsa
      dedicated = DedicatedLsaReport.new(@site, @day).rows
      imported = compare_signals("lsa_rankings", "Local Services Ads", %w[query market]) do |before, after|
        a, b = before.fetch("position"), after.fetch("position")
        "Position changed from #{a} to #{b}.#{' The listing moved outside the top three.' if a <= 3 && b > 3}"
      end
      dedicated + imported + LocalServicesPanels.new(@site, @start, @day).rows
    end

    def ai_visibility(previous_range: nil, captured_only: false)
      compare_signals("ai_visibility", "AI search", %w[engine prompt market], previous_range: previous_range) do |before, after|
        "Mention: #{yes_no(before.fetch('mentioned'))} → #{yes_no(after.fetch('mentioned'))}. " \
          "Citation: #{yes_no(before.fetch('cited'))} → #{yes_no(after.fetch('cited'))}."
      end + google_ai_overviews + ai_response_samples(captured_only: captured_only)
    end

    def ai_response_samples(captured_only:)
      samples = @site.source_snapshots.where(provider: AiVisibilitySample::PROVIDER, observed_on: @start..@day)
        .where("metrics->>'host' = ?", @site.host)
      samples = samples.where("metrics->>'status' = 'captured'") if captured_only
      samples.order(observed_on: :desc, id: :desc).limit(20).map do |snapshot|
        sample = snapshot.metrics
        coverage = AiVisibilitySample.status_text(snapshot)
        market = sample["location"] || sample.fetch("country")
        row(snapshot.title, "#{snapshot.observed_on} · #{market} · #{sample.fetch('model')}. #{coverage}",
          source_snapshot_path(snapshot))
      end
    end

    def google_ai_overviews
      key = Tracking::GoogleAiOverview::KEY
      captures = provider_rank_observations.where("jsonb_exists(rank_observations.evidence, ?)", key)
        .group("tracking_series.device", Arel.sql("rank_observations.evidence->'#{key}'->>'coverage'"),
          Arel.sql("rank_observations.evidence->'#{key}'->>'site_link_observed'")).count
      captures.group_by { |(device, _, _), _| device }.sort.map do |device, groups|
        counts = groups.to_h
        cited = counts.fetch([device, "provider_payload", "true"], 0)
        measured = cited + counts.fetch([device, "provider_payload", "false"], 0)
        unavailable = counts.fetch([device, "unavailable", nil], 0) + counts.fetch([device, "provider_payload", nil], 0)
        row("DataForSEO Google AI Overviews", "#{device.capitalize} · #{cited} of #{measured} supplied overview payloads linked to this site; " \
          "#{unavailable} had unavailable content. These counts describe the returned payloads from #{@start} through #{@day}.",
          rankings_path(source: "local", device: device, day: @day))
      end
    end

    def provider_rank_observations
      RankObservation.provider_for(@site).merge(TrackingSeries.current).where(daily_slots: { day: @start..@day })
    end

    def competitors(previous_range: nil, period: "monthly")
      comparison_start = previous_range&.begin || @start.prev_month
      comparisons = compare_signals("competitors", "Competitor market", %w[business query market], previous_range: previous_range) do |before, after|
        "Maps position #{before.fetch('map_position')} → #{after.fetch('map_position')}. " \
          "Reviews #{before.fetch('review_count')} → #{after.fetch('review_count')}. " \
          "Ad observed: #{yes_no(before.fetch('active_ad'))} → #{yes_no(after.fetch('active_ad'))}."
      end
      CompetitorPacks.new(@site, @start, @day, comparison_start: comparison_start, period: period).rows + comparisons
    end

    def post_drafts
      render_signals("post_brief") do |record|
        "#{record.fetch('service')}: #{record.fetch('approved_detail')} Learn more on our website."
      end
    end

    def reply_drafts
      render_signals("review_queue") do |record|
        reply = if record.fetch("rating") >= 4
          "Thank you for sharing your feedback. We appreciate you taking the time to leave a review."
        else
          "Thank you for your feedback. We would welcome a chance to discuss your concerns. Please contact us directly."
        end
        "#{record.fetch('review_ref')} · #{record.fetch('rating')} out of 5 · #{reply}"
      end
    end

    def prospect
      render_signals("prospect") do |record|
        "#{record.fetch('target_host')} · #{record.fetch('check').humanize} · #{record.fetch('observation')}"
      end
    end

    def yes_no(value) = value ? "yes" : "no"

    def signal_scope(kind)
      @site.source_snapshots.where(provider: EvidenceImport::PROVIDER)
        .where("metrics->>'kind' = ? AND metrics->>'host' = ?", kind, @site.host)
        .where("jsonb_typeof(metrics->'records') = 'array'")
        .order(observed_on: :desc, id: :desc)
    end

    def render_signals(kind)
      snapshot = signal_scope(kind).where(observed_on: @start..@day).first
      return [] unless snapshot

      snapshot.metrics.fetch("records").first(20).map do |record|
        row(SignalExport::TYPES.fetch(kind), yield(record), source_snapshot_path(snapshot))
      end
    end

    def compare_signals(kind, label, keys, previous_range: nil)
      scope = signal_scope(kind)
      current = scope.where(observed_on: @start..@day).first
      return [] unless current

      previous = scope.where(observed_on: previous_range || (...current.observed_on)).first
      return [] unless previous

      identity = ->(record) { record.values_at(*keys) }
      baseline = previous.metrics.fetch("records").index_by(&identity)
      current.metrics.fetch("records").first(100).filter_map do |record|
        key = identity.call(record)
        before = baseline[key]
        next unless before

        text = before == record ? "No observed change." : yield(before, record)
        row(label, "#{key.join(' · ')} · #{previous.observed_on} to #{current.observed_on}. #{text}",
          source_snapshot_path(current)).merge("baseline_path" => source_snapshot_path(previous))
      end.first(20)
    end
  end
end
