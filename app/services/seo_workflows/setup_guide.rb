module SeoWorkflows
  class SetupGuide
    Entry = Data.define(:inputs, :output, :action, :imports)
    ENTRIES = {
      "M1" => Entry.new("Add tracked keywords and save organic readings. Connect Local Falcon and verify the location to request or import a Google Maps grid.",
        "Weekly position movement by device and Maps pin changes where grids match.", :new_keyword_path, %w[geogrid]),
      "M2" => Entry.new("Ask your operator to bind DataForSEO or Local SEO Data to the exact Place ID. Run the task and check its report for pending collection. You can also import activity covering five Sundays.",
        "Weekly review volume, coverage, and alerts for drops or low-rated reviews.", :integrations_path, %w[review_activity reviews]),
      "M3" => Entry.new("Ask your operator to enable DataForSEO or Local SEO Data for the exact Place ID. Run once to establish a baseline, then enable the daily schedule. Field exports are also supported.",
        "Business Profile fields that changed between readings, with links to both samples.", :integrations_path, %w[profile_fields]),
      "M4" => Entry.new("Use verified Business Profile details and saved DataForSEO searches to check for Local Services Ads. Dedicated scans and paired position exports are also supported.",
        "Weekly position comparison with notifications for significant moves and identifiable new competitors.", :integrations_path, %w[lsa_rankings]),
      "M5" => Entry.new("Use saved Google AI Overview results, import comparable observations, or run an approved Google AI Overview, ChatGPT, Gemini or Perplexity sample below.",
        "Monthly mentions and citations with coverage for each source.", :rankings_path, %w[ai_visibility]),
      "E1" => Entry.new("Import a brief with public service details. Review the exact draft. Connect a verified Business Profile if you use in-app publishing.",
        "Post draft for owner approval, with a separate publication step when configured.", nil, %w[post_brief]),
      "E2" => Entry.new("Import unanswered review references and ratings. A verified Google Business Profile connection is needed to publish a reply in Searchdesk.",
        "Reply draft for owner approval, with a separate publication step for the exact review.", nil, %w[review_queue]),
      "E3" => Entry.new("Import reviewed public directory checks and optional listing links, then preview the current quarter. An operator can also configure Local SEO Data.",
        "Quarterly audit of mismatches, missing listings, duplicates and checked directories.", :integrations_path, %w[citation_audit citations]),
      "E4" => Entry.new("Assign preferred pages to keywords, run a site audit during the reporting quarter and import a public landing-page brief for copy or schema drafts. Compare a public page on your site with a competitor page for the same service.",
        "Crawl findings and exact drafts for owner review and manual application.", :site_audit_path, %w[landing_page_brief]),
      "R1" => Entry.new("Save rankings, a Maps scan, a website crawl or a review export for the reporting week.",
        "Week-over-week ranking, Maps and review comparisons, with one next action.", :source_snapshots_path, %w[reviews]),
      "R2" => Entry.new("Save rankings, Maps grids, review activity, M5 AI evidence or P2 competitor samples for the reporting month. Have a workspace owner review the report and confirm the recipient if email delivery is configured.",
        "Approved monthly report with optional delivery and a delivery record.", :source_snapshots_path, %w[reviews]),
      "R3" => Entry.new("Opt at least two sites in the workspace into the rollup and generate each location’s monthly report (R2). R3 runs from 10 am local time on the first day of the month when scheduled.",
        "Location metrics, priorities, missing reports and recurring issues across the portfolio.", :seo_workflows_path, []),
      "R4" => Entry.new("Save rankings, Maps scans, crawls, reviews, M5 AI evidence or P2 competitor samples during the reporting quarter.",
        "90-day trends, wins, issues, competitor and AI evidence, and ranked priorities for the next quarter.", :source_snapshots_path, %w[reviews]),
      "P1" => Entry.new("Enter the prospect’s public hostname, business name, market and search term. An optional provider lookup requires an operator-configured key.",
        "Private prospect report with page findings and optional ranking, review and competitor observations.", :prospect_audits_path, %w[prospect]),
      "P2" => Entry.new("Track a keyword and market with DataForSEO. Recover evidence from saved DataForSEO rankings below. Comparison requires complete local packs from successive months for the same search, market and device.",
        "Monthly report of listing movement, review changes and sampled sponsored appearances.", :rankings_path, %w[competitors])
    }.freeze

    IMPORT_HEADERS = {
      "geogrid" => "rank",
      "review_activity" => "week_ending,new_reviews,average_rating,unanswered_low_rating,new_one_star",
      "reviews" => "rating",
      "profile_fields" => "field,value",
      "lsa_rankings" => "query,market,position",
      "ai_visibility" => "engine,prompt,market,mentioned,cited",
      "post_brief" => "service,approved_detail",
      "review_queue" => "review_ref,rating",
      "citation_audit" => "directory,listing_key,status,tier,name_match,address_match,phone_match",
      "citations" => "directory,status",
      "landing_page_brief" => "page,heading,paragraph,draft_storefront_schema,business_name,street_address,locality,region,postal_code,country_code,telephone",
      "prospect" => "target_host,check,observation",
      "competitors" => "business,query,market,map_position,review_count,active_ad"
    }.freeze

    attr_reader :maps_revision, :maps_keywords, :maps_request, :maps_grid, :page_comparisons, :results, :scheduled, :prospect, :publish_ready, :ai_settings, :ai_samples, :competitor_series, :local_services_series

    def initialize(site, owner:)
      @site = site
      if owner
        @ai_settings = AiVisibilitySample.web_settings(site)
        @competitor_series = Tracking::SerpEvidenceRecovery.available_series(site, feature: "P2")
        @local_services_series = Tracking::SerpEvidenceRecovery.available_series(site, feature: "M4")
      end
      @maps_revision = LocalFalcon::ScanCollection.revision(site) if owner
      @maps_keywords = site.keywords.order(priority: :desc, phrase: :asc).limit(100) if @maps_revision
      @maps_request = LocalFalcon::ScanCollection.scope(site).order(observed_on: :desc, id: :desc).first
      @maps_grid = LocalFalcon::GeogridExport.scope(site).order(observed_on: :desc, id: :desc).first
      @page_comparisons = PageComparison.scope(site).order(observed_on: :desc, id: :desc).limit(5)
      @ai_samples = site.source_snapshots.where(provider: AiVisibilitySample::PROVIDER)
        .where("metrics->>'host' = ?", site.host).order(created_at: :desc, id: :desc).limit(6)
      @results = site.seo_workflow_runs.where(site_host: site.host)
        .select(Arel.sql("DISTINCT ON (template_key) seo_workflow_runs.*"))
        .order(Arel.sql("template_key, period_on DESC, id DESC")).index_by(&:template_key)
      @scheduled = site.seo_workflow_schedules.pluck(:template_key).to_set
      @imports = site.source_snapshots.where(provider: EvidenceImport::PROVIDER)
        .where("metrics->>'host' = ?", site.host).distinct.pluck(Arel.sql("metrics->>'kind'"))
      @prospect = site.prospect_audits.where(site_host: site.host).order(created_at: :desc, id: :desc).first if owner
      @publish_ready = !!site.business_profile_connection&.connected?
      @ranking_mode = site.keywords.exists? ? site.tracking_mode : nil
      @has_crawl = site.site_audits.where(host: site.host, status: %w[complete partial]).exists?
      @has_connected_maps = site.local_falcon_connection&.status == "connected"
      @rollup = site.seo_workflow_rollup_enabled? && site.workspace.sites.where(seo_workflow_rollup_enabled: true).count >= 2
    end

    def live_schedule?(key)
      LocalSeoData::Collection.scheduled?(@site, key)
    end

    def result_status(run)
      if run.template_key == "M2"
        receipt = LocalSeoData::Collection.receipt(@site, "M2", run.period_on)
        return "Awaiting provider results" if receipt&.metrics&.fetch("host", nil) == @site.host &&
          receipt.metrics["state"].in?(%w[collecting submitted])
      end
      if run.template_key == "R3"
        rows = Rollup.visible_rows(@site, run.result)
        return "Portfolio unavailable" if rows.empty?
        return "Partial coverage" if Rollup.summary(rows).fetch("coverage") == "partial"
      end
      run.effective_status.humanize
    end

    def input_label(key)
      entry = ENTRIES.fetch(key)
      return "Live sampling configured · DataForSEO" if key == "M5" && ai_settings
      if LocalSeoData::Collection.enabled?(@site, key)
        return "Live collection configured · DataForSEO" if LocalSeoData::Collection.data_for_seo?(@site, key)

        return "Live collection configured"
      end
      return "On-demand website audit available" if key == "P1"
      return "DataForSEO search receipts available" if key == "M4" && local_services_series.present?
      return @rollup ? "Locations opted in" : "Requires two opted-in locations" if key == "R3"
      return "Crawl and assigned page evidence" if key == "E4" && @has_crawl && @site.keywords.where.not(preferred_url: [nil, ""]).exists?
      return "Evidence imported" if (@imports & entry.imports).any?
      if %w[M1 M5 P2 R1 R2 R4].include?(key)
        return "Ranking tracking configured" if @ranking_mode == "dataforseo"
        return "Simulated rankings available" if @ranking_mode == "demo" && %w[M1 R1 R2 R4].include?(key)
        return "Manual rankings configured" if @ranking_mode == "manual" && %w[M1 R1 R2 R4].include?(key)
      end
      return "Local Falcon connected" if @has_connected_maps && %w[M1 R1 R2 R4].include?(key)
      return "Crawl evidence saved" if @has_crawl && %w[R1 R2 R4].include?(key)

      "Setup or evidence needed"
    end
  end
end
