module SeoWorkflows
  class EvidenceBundle
    include Rails.application.routes.url_helpers

    LIMIT = 100
    EVIDENCE_PATH = %r{\A/(?:source_snapshots|seo_workflows/competitor_capture)/[1-9]\d*\z}

    def initialize(site)
      @site = site
    end

    def build
      exports = @site.source_snapshots.where(provider: EvidenceImport::PROVIDER)
        .where("metrics->>'host' = ?", @site.host).order(observed_on: :desc, id: :desc)
      runs = @site.seo_workflow_runs.where(site_host: @site.host, status: %w[complete approved delivered])
        .order(period_on: :desc, id: :desc)
      {
        "schema" => "searchdesk-seo-evidence-v1",
        "site_host" => @site.host,
        "site_scope" => OpenSSL::HMAC.hexdigest("SHA256",
          Rails.application.key_generator.generate_key("seo-brain-export", 32), "#{@site.workspace_id}:#{@site.id}"),
        "generated_at" => Time.current.iso8601(6),
        "includes_at_most_per_section" => LIMIT,
        "sources" => exports.limit(LIMIT).map do |source|
          {
            "title" => source.title, "observed_on" => source.observed_on.iso8601, "reference" => source.external_id,
            "observations" => source.metrics.except("host")
          }
        end,
        "maps_grids" => LocalFalcon::GeogridExport.scope(@site).order(observed_on: :desc, id: :desc)
          .limit(LocalFalcon::GeogridExport::LIMIT).filter_map { |snapshot| LocalFalcon::GeogridExport.entry(snapshot) },
        "reports" => runs.limit(LIMIT).filter_map { |run| report_entry(run) }
      }
    end

    private

    def report_entry(run)
      rows = run.result
      entry = { "template" => run.template_key, "period_on" => run.period_on.iso8601, "status" => run.status }
      if run.template_key == "R3"
        rows = Rollup.visible_rows(@site, rows)
        return if rows.empty?

        summary = Rollup.summary(rows)
        summary["locations"] = summary.fetch("locations").map do |location|
          location.except("id", "report_id").merge("report_path" => ("/seo_workflows/#{location['report_id']}" if location["report_id"])).compact
        end
        entry["rollup"] = summary
      end
      if run.template_key == "R4" && (review = rows.find { |row| row["quarterly_review"] }&.fetch("quarterly_review"))
        entry["quarterly_review"] = review.merge(
          "competitors" => review.fetch("competitors").map { |row| export_row(row) },
          "ai_evidence" => review.fetch("ai_evidence").map { |row| export_row(row) }
        )
      end
      if run.template_key == "R1" && (weekly = rows.find { |row| row["weekly_performance"] })
        entry["report_path"] = seo_workflow_path(run)
        entry["weekly_performance"] = weekly.fetch("weekly_performance")
      end
      entry.merge("evidence" => rows.map { |row| export_row(row) })
    end

    def export_row(row)
      result = row.slice("source", "text")
      result["source_path"] = row["path"] if EVIDENCE_PATH.match?(row["path"].to_s)
      result["comparison_path"] = row["baseline_path"] if EVIDENCE_PATH.match?(row["baseline_path"].to_s)
      result
    end
  end
end
