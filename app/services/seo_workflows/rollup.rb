module SeoWorkflows
  class Rollup
    include Rails.application.routes.url_helpers

    REPORT_STATUSES = %w[awaiting_approval approved delivered expired].freeze
    SEVERITY = %w[Urgent Monitor Healthy].freeze
    ISSUES = {
      "reviews_unanswered" => "Unanswered low-rated reviews",
      "new_one_star" => "New one-star reviews",
      "review_velocity" => "Review volume declined",
      "visibility" => "Maps visibility or rank declined",
      "citation_conflict" => "Critical directory listing conflicts"
    }.freeze

    def self.locations(site)
      site.workspace.sites.where(seo_workflow_rollup_enabled: true)
    end

    def self.visible_rows(site, rows)
      locations = locations(site).pluck(:id, :host).to_h
      return [] unless locations.key?(site.id) && locations.size >= 2

      rows.select do |row|
        record = row["rollup_location"]
        record && locations[record["id"]] == record["host"]
      end
    end

    def self.summary(rows)
      records = rows.pluck("rollup_location")
      counts = records.flat_map { |record| record.fetch("issues").keys }.tally
      reports = records.count { |record| record["report_id"] }
      {
        "coverage" => reports == records.size ? "complete" : "partial",
        "reported_locations" => reports, "total_locations" => records.size,
        "brand_patterns" => counts.select { |_, count| count >= 3 },
        "local_patterns" => counts.select { |_, count| count < 3 },
        "locations" => records
      }
    end

    def initialize(site:, day:, now:)
      @site, @day, @now = site, day, now
      @start = day.beginning_of_month
      @previous = @start.prev_month...@start
    end

    def rows
      locations = self.class.locations(@site).order(:id).to_a
      return [] unless locations.size >= 2 && locations.include?(@site)

      reports = SeoWorkflowRun.where(site_id: locations.map(&:id), template_key: "R2", period_on: @day,
        status: REPORT_STATUSES).index_by { |report| [report.site_id, report.site_host] }
      locations.map do |site|
        report = reports[[site.id, site.host]]
        location_row(site, report)
      end.sort_by do |row|
        record = row.fetch("rollup_location")
        [SEVERITY.index(record.fetch("status")), -record.fetch("critical_issues"), record.fetch("name").downcase, record.fetch("id")]
      end
    end

    private

    def location_row(site, report)
      maps = report ? maps_metrics(site) : {}
      reviews = report ? review_metrics(site) : {}
      issues = {}
      issues["reviews_unanswered"] = reviews["unanswered"] if reviews["unanswered"].to_i.positive?
      issues["new_one_star"] = reviews["one_star"] if reviews["one_star"].to_i.positive?
      issues["review_velocity"] = true if reviews["direction"] == "down"
      issues["visibility"] = true if maps["solv_change"].to_f.negative? || maps["arp_change"].to_f.positive?
      if report && (conflicts = citation_conflicts(site)).positive?
        issues["citation_conflict"] = conflicts
      end
      critical = issues.fetch("citation_conflict", 0) + issues.fetch("reviews_unanswered", 0)
      incomplete = !report || maps["solv"].nil? || reviews["covered_weeks"] != reviews["expected_weeks"] || reviews["expected_weeks"].nil?
      status = if critical.positive?
        "Urgent"
      elsif issues.any? || incomplete
        "Monitor"
      else
        "Healthy"
      end
      record = { "id" => site.id, "host" => site.host, "name" => site.name, "status" => status,
        "report_id" => report&.id, "critical_issues" => critical, "issues" => issues, "maps" => maps, "reviews" => reviews }
      text = report ? "#{site.name} · #{status} · Monthly report dated #{report.period_on}." : "#{site.name} · #{status} · Monthly report missing."
      { "source" => "Location monthly report", "text" => text, "path" => seo_workflows_path,
        "rollup_location" => record, "attention" => status != "Healthy" }
    end

    def maps_metrics(site)
      scans = LocalFalcon::MapsSummary.verified_scan_scope(site).order(observed_on: :desc, id: :desc)
      current = scans.where(observed_on: @start..@day).limit(60).find do |scan|
        measure = LocalFalcon::MapsSummary.new(scan)
        measure.share || measure.average_rank
      end
      return {} unless current

      measure = LocalFalcon::MapsSummary.new(current)
      grid = LocalFalcon::ScanGrid.new(current)
      prior = scans.where(observed_on: @previous).where("LOWER(keyword) = ?", current.keyword.downcase)
        .where.not(map_grid: nil).limit(20).find { |scan| grid.matches?(LocalFalcon::ScanGrid.new(scan)) }
      baseline = LocalFalcon::MapsSummary.new(prior) if prior
      share = measure.share
      rank = measure.average_rank
      {
        "keyword" => current.keyword, "observed_on" => current.observed_on.iso8601,
        "average_rank" => rank, "solv" => share, "previous_on" => prior&.observed_on&.iso8601,
        "arp_change" => change(rank, baseline&.average_rank),
        "solv_change" => change(share, baseline&.share)
      }.compact
    end

    def change(current, previous)
      (current - previous).round(2) if current && previous
    end

    def review_metrics(site)
      current_days = WeeklyReviewEvidence.full_weeks(@start..@day)
      prior_days = WeeklyReviewEvidence.full_weeks(@previous.begin..(@start - 1))
      feeds = WeeklyReviewEvidence.new(site: site, start: @previous.begin, day: @day, now: @now).feeds
      feed = feeds.max_by do |records|
        [(current_days & records.keys).size, (prior_days & records.keys).size]
      end || {}
      current = feed.values_at(*current_days).compact
      prior = feed.values_at(*prior_days).compact
      coverage = { "covered_weeks" => current.size, "expected_weeks" => current_days.size }
      return coverage if current.empty?

      total = current.sum { |week| week.fetch("new_reviews") }
      rated = current.select { |week| week["average_rating"].is_a?(Numeric) }
      if total.positive? && rated.sum { |week| week.fetch("new_reviews") } == total
        rating = rated.sum { |week| week.fetch("average_rating") * week.fetch("new_reviews") }.fdiv(total).round(2)
      end
      direction = if current.size == current_days.size && prior.size == prior_days.size && prior.any?
        prior_total = prior.sum { |week| week.fetch("new_reviews") }
        %w[down steady up].fetch((total * prior.size <=> prior_total * current.size) + 1)
      end
      coverage.merge("count" => total, "rating" => rating, "direction" => direction,
        "unanswered" => current.sum { |week| week.fetch("unanswered_low_rating") },
        "one_star" => current.sum { |week| week.fetch("new_one_star") }).compact
    end

    def citation_conflicts(site)
      audit = site.source_snapshots.where(provider: [EvidenceImport::PROVIDER, LocalSeoData::Collection::PROVIDER],
        observed_on: @start..@day).where("metrics->>'host' = ? AND metrics->>'kind' = 'citation_audit'", site.host)
        .where("jsonb_typeof(metrics->'records') = 'array'").order(observed_on: :desc, id: :desc).first
      Array(audit&.metrics&.fetch("records", nil)).count do |directory|
        (directory.fetch("issues") & %w[address_mismatch phone_mismatch duplicate_listings]).any?
      end
    end
  end
end
