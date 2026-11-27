module SeoWorkflows
  class Report
    include Rails.application.routes.url_helpers
    include SignalReports
    include OperationalReports

    def initialize(site:, template:, day:, now:)
      @site, @template, @day, @now = site, template, day, now
      @start = template.period_start(day)
    end

    def rows
      case @template.reader
      when :rankings then rankings + maps_activity + export("geogrid", "Geogrid", %w[ranked_samples top_three_samples])
      when :reviews then review_activity + export("reviews", "Reviews", %w[rated_rows average_rating])
      when :citations then citation_audit + export("citations", "Citations", %w[directory_rows rows_with_reported_status])
      when :audit then landing_page_audit + page_comparisons
      when :report then performance_report
      when :rollup then Rollup.new(site: @site, day: @day, now: @now).rows
      else send(@template.reader)
      end
    end

    private

    def performance_report
      rows = rankings + maps_activity + audit + saved_review_activity + export("reviews", "Reviews", %w[rated_rows average_rating])
      if @template.key == "R1"
        weekly = WeeklyPerformance.new(site: @site, day: @day, now: @now).row(has_saved_evidence: rows.any?)
        return [weekly, *rows].compact
      end

      previous_range = @template.period_start(@start - 1)...@start
      ai = ai_visibility(previous_range: previous_range, captured_only: true)
      competitive = competitors(previous_range: previous_range, period: @template.cadence.to_s)
      return rows + ai + competitive unless @template.key == "R4"

      review = QuarterlyReview.new(site: @site, day: @day, now: @now)
        .row(competitors: competitive, ai_evidence: ai, has_saved_evidence: rows.any?)
      [review, *rows, *ai, *competitive].compact
    end

    def rankings
      scope = RankObservation.joins(daily_slot: { tracking_series: :keyword })
        .merge(TrackingSeries.current)
        .where(keywords: { site_id: @site.id }, tracking_series: { source: @site.tracking_mode },
          daily_slots: { day: @start..@day })
      readings = scope.group("tracking_series.device", "rank_observations.status").count
      movement = movement_by_device(scope)
      readings.group_by { |(device, _), _| device }.sort.map do |device, counts|
        totals = counts.to_h.transform_keys(&:last)
        label = @site.tracking_mode == "demo" ? "Simulated organic rankings" : "Saved organic rankings"
        text = "#{device.capitalize} · #{totals.fetch('ranked', 0)} ranked, #{totals.fetch('outside', 0)} outside the tracked range, " \
          "#{totals.fetch('incomplete', 0)} incomplete observations from #{@start} to #{@day}. Counts describe coverage."
        if (changes = movement[device])
          text += " In series with at least two measured ranks, #{changes.count(&:positive?)} improved, " \
            "#{changes.count(&:negative?)} declined and #{changes.count(&:zero?)} were unchanged from first to last measurement."
        end
        row(label, text, rankings_path(source: "local", device: device, day: @day))
      end
    end

    def movement_by_device(scope)
      measured = scope.where(status: "ranked").where.not(position: nil)
        .order("daily_slots.day").pluck("tracking_series.id", "tracking_series.device", :position)
      changes = measured.group_by(&:first).values.filter_map do |series|
        next if series.size < 2

        [series.first[1], series.first.last - series.last.last]
      end
      changes.group_by(&:first).transform_values { |device_rows| device_rows.map(&:last) }
    end

    def latest_audit
      @site.site_audits.where(host: @site.host, status: %w[complete partial])
        .where(finished_at: @start.in_time_zone(@site.time_zone)...(@day + 1).in_time_zone(@site.time_zone))
        .where(finished_at: ..@now).order(finished_at: :desc, id: :desc).first
    end

    def audit(saved = latest_audit)
      return [] unless saved

      [row("Website crawl", "A #{saved.status} crawl finished on #{saved.finished_at.in_time_zone(@site.time_zone).to_date}. " \
        "Review the saved title, heading and indexing findings before choosing changes.", site_audit_path(run: saved.id))]
    end

    def landing_page_audit
      saved = latest_audit
      return [] unless saved

      path = site_audit_path(run: saved.id)
      scope = SiteAudits::PublicUrl.new(@site.host)
      base = URI("https://#{@site.host}/")
      targets = @site.keywords.where.not(preferred_url: [nil, ""]).order(:id).limit(100).filter_map do |keyword|
        scope.resolve(keyword.preferred_url, base: base)&.path
      end.uniq
      return audit(saved) + [row("Landing pages", "Assign preferred pages to tracked keywords to audit them here.", path)] if targets.empty?

      pages = Array(saved.report["pages"]).grep(Hash).index_by { |page| page["path"] }
      crawled = targets.filter_map { |target| pages[target] }
      summary = row("Landing page coverage", "#{crawled.size} of #{targets.size} assigned pages appeared in this crawl.", path)
      findings = crawled.flat_map do |page|
        Array(page["issues"]).filter_map do |code|
          check = SiteAudits::Crawler::CHECKS[code]
          row(check.first, "#{page.fetch('path')} · #{check.last}", path) if check
        end
      end
      brief = signal_scope(LandingPageBrief::KIND).where(observed_on: ..@now.in_time_zone(@site.time_zone).to_date).first
      drafts = brief ? LandingPageDrafts.new(brief, path, host: @site.host) : nil
      content = drafts ? crawled.flat_map { |page| drafts.for_page(page) } : []
      audit(saved) + [summary] + findings.first(20) + content.first(20)
    end

    def page_comparisons
      PageComparison.scope(@site).where(observed_on: @start..@day)
        .where("metrics->>'status' IN (?)", %w[complete partial unavailable])
        .order(observed_on: :desc, id: :desc).limit(10).map do |snapshot|
          row(snapshot.title, "#{snapshot.observed_on} · #{PageComparison.status_text(snapshot)}", source_snapshot_path(snapshot))
        end
    end

    def export(kind, label, fields)
      snapshot = @site.source_snapshots.where(provider: EvidenceImport::PROVIDER, observed_on: @start..@day)
        .where("metrics->>'kind' = ? AND metrics->>'host' = ?", kind, @site.host)
        .order(observed_on: :desc, id: :desc).first
      return [] unless snapshot && fields.all? { |key| snapshot.metrics[key].is_a?(Numeric) }

      measures = fields.map { |key| "#{key.humanize}: #{snapshot.metrics.fetch(key)}" }.join(", ")
      [row(label, "Export dated #{snapshot.observed_on}. #{measures}. Counts describe the supplied sample.",
        source_snapshot_path(snapshot))]
    end

    def row(source, text, path)
      { "source" => source, "text" => text, "path" => path }
    end
  end
end
