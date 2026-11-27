require "test_helper"

class SeoWorkflowsTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "seo-owner@example.test", password: "long-seo-test-password")
    workspace = Workspace.create!(name: "SEO workflow workspace")
    @membership = workspace.memberships.create!(user: @user, role: "owner")
    @site = workspace.sites.create!(name: "Garden clinic", host: "garden.example", location: "Bath", time_zone: "Europe/London")
    post login_path, params: { session: { email: @user.email, password: "long-seo-test-password" } }
  end

  test "owner opens task catalogue from schedules and automation publishes one result per period" do
    travel_to Time.utc(2026, 6, 1, 7, 15) do
      DemoSiteSetup.call(@site.tap { |site| site.update!(tracking_mode: "demo") })
      get schedules_path
      assert_select "a[href=?]", seo_workflows_path, text: "SEO tasks"
      get seo_workflows_path
      assert_select ".schedule-row", count: 15

      post schedule_seo_workflows_path, params: { template: "M1", enabled: "1" }
      assert_redirected_to seo_workflows_path
      assert_difference -> { @site.seo_workflow_runs.count }, 1 do
        2.times { SeoWorkflowScheduleJob.perform_now }
      end
      run = @site.seo_workflow_runs.find_by!(template_key: "M1")
      assert_equal "complete", run.status
      assert_equal Date.new(2026, 5, 31), run.period_on
      get seo_workflow_path(run)
      assert_response :success
      assert_select "li", text: /Simulated organic rankings.*first to last measurement/
      assert_select "button", text: "Approve draft", count: 0

      post run_seo_workflows_path, params: { template: "unknown" }
      assert_response :unprocessable_entity
    end
  end

  test "notify report needs owner approval and keeps delivery separate" do
    travel_to Time.utc(2026, 6, 1, 8) do
      saved_audit(@site)
      post run_seo_workflows_path, params: { template: "R2" }
      run = @site.seo_workflow_runs.find_by!(template_key: "R2")
      assert_redirected_to seo_workflow_path(run)
      assert_equal "awaiting_approval", run.status

      patch record_delivery_seo_workflow_path(run)
      assert_equal "awaiting_approval", run.reload.status
      @membership.update!(role: "manager")
      patch review_seo_workflow_path(run), params: { decision: "approve" }
      assert_response :forbidden
      @membership.update!(role: "owner")
      patch review_seo_workflow_path(run), params: { decision: "approve" }
      assert_equal @user.id, run.reload.reviewed_by_id
      assert_nil run.delivered_at
      patch record_delivery_seo_workflow_path(run)
      assert_equal "delivered", run.reload.status
      assert_equal @user.id, run.delivered_by_id
    end
  end

  test "drafts expire and another workspace cannot view or mutate them" do
    other = Workspace.create!(name: "Other").sites.create!(name: "Other", host: "other.example", location: "Paris")
    travel_to Time.utc(2026, 7, 1, 8) do
      saved_audit(other)
      saved_audit(@site)
      template = SeoWorkflows::Catalogue.fetch("E4")
      foreign_run = SeoWorkflowRun.generate!(site: other, template: template, day: Date.new(2026, 6, 30))
      @run = SeoWorkflowRun.generate!(site: @site, template: template, day: Date.new(2026, 6, 30))
      get seo_workflow_path(foreign_run)
      assert_response :not_found
      patch review_seo_workflow_path(foreign_run), params: { decision: "approve" }
      assert_response :not_found
      assert_equal "awaiting_approval", foreign_run.reload.status
    end
    travel_to Time.utc(2026, 7, 5, 8) do
      patch review_seo_workflow_path(@run), params: { decision: "approve" }
      assert_equal "expired", @run.reload.effective_status
      assert_nil @run.reviewed_at
    end
  end

  test "review imports discard identities and refresh the missing-evidence result without duplicating it" do
    travel_to Time.utc(2026, 6, 1, 8) do
      post run_seo_workflows_path, params: { template: "M2" }
      run = @site.seo_workflow_runs.find_by!(template_key: "M2")
      assert_equal "missing_evidence", run.status

      Tempfile.create(["review-export", ".json"]) do |file|
        file.write([{ rating: 5, author: "Private reviewer", text: "Private review body" }, { rating: 3 }].to_json)
        file.flush
        2.times do
          post import_evidence_seo_workflows_path, params: { kind: "reviews", observed_on: "2026-05-31",
            export: Rack::Test::UploadedFile.new(file.path, "application/json") }
          assert_response :see_other
        end
      end

      source = @site.source_snapshots.sole
      assert_equal 4.0, source.metrics.fetch("average_rating")
      refute_includes source.attributes.to_json, "Private reviewer"
      refute_includes source.attributes.to_json, "Private review body"
      assert_no_difference -> { @site.seo_workflow_runs.count } do
        post run_seo_workflows_path, params: { template: "M2" }
      end
      assert_equal "complete", run.reload.status
      get seo_workflow_path(run)
      assert_select "a[href=?]", source_snapshot_path(source)
    end
  end

  test "geogrid, citations and generic profiles save only derived CSV metrics" do
    examples = {
      "geogrid" => ["keyword,rank\nHeating,2\nHeating,6\n", "top_three_samples", 1],
      "citations" => ["directory,url,status\nDirectory,https://example.test/,listed\n", "directory_rows", 1],
      "gbp" => ["name,phone\nPrivate profile,123456789\n", "column_count", 2],
      "manual" => ["heading\nExample private text\n", "export_rows", 1]
    }
    examples.each do |kind, (csv, metric, value)|
      Tempfile.create(["evidence-export", ".csv"]) do |file|
        file.write(csv)
        file.flush
        assert_difference -> { @site.source_snapshots.count }, 1 do
          post import_evidence_seo_workflows_path, params: { kind: kind, observed_on: "2025-01-01",
            export: Rack::Test::UploadedFile.new(file.path, "text/csv") }
        end
        snapshot = @site.source_snapshots.order(:id).last
        assert_equal value, snapshot.metrics.fetch(metric)
        refute_includes snapshot.attributes.to_json, csv.lines.last.strip
      end
    end
  end

  test "weekly review activity measures a closed week and queues one attention notification" do
    travel_to Time.utc(2026, 6, 1, 8) do
      post schedule_seo_workflows_path, params: { template: "M2", enabled: "1" }
      SeoWorkflowScheduleJob.perform_now
      assert_equal "missing_evidence", @site.seo_workflow_runs.sole.status
    end
    travel_to Time.utc(2026, 6, 2, 8) do
      csv = <<~CSV
        week_ending,new_reviews,average_rating,unanswered_low_rating,new_one_star,author
        2026-05-31,2,4.1,1,1,Private name
        2026-05-24,10,4.5,0,0,
        2026-05-17,10,4.5,0,0,
        2026-05-10,10,4.5,0,0,
        2026-05-03,10,4.5,0,0,
      CSV
      upload_csv("review_activity", "2026-06-02", csv)
      source = @site.source_snapshots.sole
      refute_includes source.metrics.to_json, "Private name"

      2.times { SeoWorkflowScheduleJob.perform_now }
      run = @site.seo_workflow_runs.sole
      get seo_workflow_path(run)
      assert_select "li", text: /volume fell by more than 40%/
      assert_select "li", text: /1 unanswered low-rated reviews/
      assert_select "a[href=?]", source_snapshot_path(source)
      assert_equal "attention", SeoWorkflowNotification.where(seo_workflow_run: run).sole.kind
    end
  end

  test "citation audit classifies findings and compares only overlapping directories" do
    travel_to Time.utc(2026, 7, 1, 8) do
      headers = "directory,listing_key,status,tier,name_match,address_match,phone_match
"
      upload_csv("citation_audit", "2026-03-30", headers +
        "one.example,old-listing,listed,1,false,true,true
old.example,,missing,2,,,
")
      upload_csv("citation_audit", "2026-06-29", headers +
        "www.one.example,private-key,listed,1,true,true,false
one.example,another-key,listed,1,true,true,true
new.example,,missing,3,,,
")
      source = @site.source_snapshots.order(:id).last
      refute_includes source.metrics.to_json, "private-key"

      post run_seo_workflows_path, params: { template: "E3" }
      follow_redirect!
      assert_select "li", text: /Across 1 directories in both audits, 2 new issues and 1 resolved/
      assert_select "li", text: /Critical.*one.example.*Duplicate listings.*Phone mismatch/m
      assert_select "li", text: /Monitor.*new.example.*Missing listing/m
      assert_equal "attention", SeoWorkflowNotification.sole.kind
    end
  end

  test "E3 previews dated citation sources and excludes unverified fields from changes" do
    travel_to Time.utc(2026, 7, 1, 10) do
      headers = "directory,listing_key,status,tier,name_match,address_match,phone_match,listing_url\n"
      upload_csv("citation_audit", "2026-06-29", headers +
        "one.example,old-key,listed,1,true,true,false,https://one.example/business\n" \
        "two.example,previous,listed,2,false,true,true,https://two.example/business\n")
      upload_csv("citation_audit", "2026-07-01", headers +
        "one.example,private-key,listed,1,true,false,unknown,https://www.one.example/business\n" \
        "two.example,,unverified,2,,,,\n")

      get setup_seo_workflows_path
      assert_select "#E3 a[href=?]", evidence_preview_seo_workflows_path(template: "E3")
      assert_no_difference "SeoWorkflowRun.count" do
        get evidence_preview_seo_workflows_path(template: "E3")
        assert_select "li", text: /1 unverified directories.*1 directories had unverified fields/
        assert_select "li", text: /Across 1 directories in both audits, 1 new issues and 0 resolved/
        assert_select "li", text: /Critical.*Address mismatch/m
        refute_includes response.body, "Phone mismatch"
      end
      source = @site.source_snapshots.order(:observed_on).last
      get source_snapshot_path(source)
      assert_select "a[href=?][rel=?]", "https://www.one.example/business", "noopener noreferrer"
      assert_select "p", text: /Unverified fields.*phone/
      assert_select "p", text: /Listing presence unverified/
      refute_includes response.body, "private-key"
      refute_includes source.metrics.to_json, "private-key"

      original = @site.source_snapshots.count
      upload_csv("citation_audit", "2026-07-01", headers +
        "one.example,bad-url,listed,1,true,true,true,https://outside.example/public\n")
      assert_equal original, @site.source_snapshots.count
    end
  end

  test "E4 queues findings for assigned pages and reports crawl coverage" do
    travel_to Time.utc(2026, 7, 1, 8) do
      @site.keywords.create!(phrase: "garden clinic", preferred_url: "https://garden.example/location")
      @site.keywords.create!(phrase: "garden service", preferred_url: "https://garden.example/uncrawled")
      saved_audit(@site).update!(report: { "pages" => [
        { "path" => "/location", "issues" => ["missing_h1", "noindex"] },
        { "path" => "/other", "issues" => ["missing_description"] }
      ] })

      post run_seo_workflows_path, params: { template: "E4" }
      follow_redirect!
      assert_select "li", text: /1 of 2 assigned pages/
      assert_select "li", text: /Missing main heading.*location.*visible main heading/
      assert_select "li", text: /Indexing disabled.*location/
      assert_select "li", text: /Missing meta description/, count: 0
      assert_select "button", text: "Approve draft"
      assert_equal "awaiting_approval", @site.seo_workflow_runs.sole.status
    end
  end

  test "E4 previews site-scoped copy and JSON-LD and protects approval across a refresh" do
    travel_to Time.utc(2026, 7, 1, 8) do
      %w[location existing hidden].each do |path|
        @site.keywords.create!(phrase: path, preferred_url: "https://garden.example/#{path}")
      end
      saved_audit(@site).update!(report: { "pages" => [
        { "path" => "/location", "html" => true, "h1_count" => 0, "main_word_count" => 25,
          "structured_markup_present" => false, "issues" => ["missing_h1"] },
        { "path" => "/existing", "html" => true, "h1_count" => 1, "main_word_count" => 650,
          "structured_markup_present" => true, "issues" => [] },
        { "path" => "/hidden", "html" => true, "h1_count" => 0, "main_word_count" => 1,
          "structured_markup_present" => false, "issues" => ["noindex"] }
      ] })

      headers = "page,heading,paragraph,draft_storefront_schema,business_name,street_address,locality,region,postal_code,country_code,telephone
"
      post run_seo_workflows_path, params: { template: "E4" }
      run = @site.seo_workflow_runs.sole
      old_revision = run.draft_revision
      brief = headers + "/location,Garden clinic in Bath,Visitors can enter from Example Street.,true,Garden Clinic,1 Example Street,Bath,,BA1 1AA,GB,+441632960000
" \
        "/existing,Skip existing heading,Skip long page,false,,,,,,,
/hidden,Skip noindex heading,,false,,,,,,,
"
      upload_csv("landing_page_brief", "2026-07-01", brief)

      @membership.update!(role: "manager")
      patch refresh_draft_seo_workflow_path(run)
      assert_response :forbidden
      @membership.update!(role: "owner")
      patch refresh_draft_seo_workflow_path(run)
      follow_redirect!
      assert_select "pre.schedule-draft", count: 3
      assert_select "pre.schedule-draft", text: "Garden clinic in Bath"
      assert_select "pre.schedule-draft", text: "Visitors can enter from Example Street."
      assert_select "a[href=?]", source_snapshot_path(@site.source_snapshots.sole), text: "View landing page brief"
      refute_includes response.body, "Skip noindex heading"
      refute_includes response.body, "Skip existing heading"
      draft = run.reload.result.find { |row| row["source"] == "LocalBusiness JSON-LD draft" }
      assert_equal ["Garden Clinic", "https://garden.example/location#localbusiness", "+441632960000"],
        JSON.parse(draft.fetch("draft")).values_at("name", "@id", "telephone")

      patch review_seo_workflow_path(run), params: { decision: "approve", revision: old_revision }
      assert_equal "awaiting_approval", run.reload.status
      current_revision = run.draft_revision
      patch review_seo_workflow_path(run), params: { decision: "approve", revision: current_revision }
      assert_equal "approved", run.reload.status
      patch refresh_draft_seo_workflow_path(run)
      assert_equal current_revision, run.reload.draft_revision
      get seo_workflow_path(run)
      assert_select "button", text: "Refresh pending draft", count: 0
      assert_select "pre.schedule-draft", count: 3
    end
  end

  test "E4 compares extended storefront fields from a crawl and keeps replacement drafts approval bound" do
    travel_to Time.utc(2026, 7, 1, 8) do
      @site.keywords.create!(phrase: "garden clinic", preferred_url: "https://garden.example/location")
      post_path = seo_workflows_path(evidence: "landing_page_brief")
      get post_path
      assert_select "code", text: "business_type,latitude,longitude,opening_hours"
      headers = "page,draft_storefront_schema,business_name,street_address,locality,country_code,telephone,business_type,latitude,longitude,opening_hours\n"
      brief = headers + "/location,true,Garden Clinic,1 Example Street,Bath,GB,+441632960000,MedicalClinic,51.38123,-2.35912,Mo-Fr 09:00-17:00 | Sa 10:00-14:00\n"
      upload_csv("landing_page_brief", "2026-07-01", brief)

      node = { "@type" => ["LocalBusiness", "https://schema.org/MedicalClinic"], "@id" => "https://garden.example/location#business",
        "name" => "Garden Clinic", "telephone" => "+44 1632 960000",
        "address" => { "streetAddress" => "1 Example Street", "addressLocality" => "Bath", "addressCountry" => "GB" },
        "geo" => { "latitude" => 51.38234, "longitude" => "-2.359120" },
        "openingHoursSpecification" => [
          { "dayOfWeek" => ["https://schema.org/Friday", "Tuesday", "Monday", "Thursday", "Wednesday"],
            "opens" => "09:00:00", "closes" => "17:00" },
          { "dayOfWeek" => "Saturday", "opens" => "10:00", "closes" => "14:00" },
          { "dayOfWeek" => "Monday", "opens" => "00:00", "closes" => "00:00", "validFrom" => "2026-12-25" }
        ] }
      pages = {
        "/" => '<html><title>Home</title><a href="/location">Visit</a></html>',
        "/location" => %(<html><title>Location</title><h1>Visit</h1><script type="application/ld+json">#{JSON.generate("@graph" => [node])}</script></html>)
      }
      fetcher = Object.new
      fetcher.define_singleton_method(:get) do |uri, robots: false|
        SiteAudits::Fetcher::Response.new(robots ? 404 : 200, nil, "text/html", "", pages.fetch(uri.path, ""))
      end
      crawl = SiteAudits::Crawler.new(host: @site.host, fetcher: fetcher, sleeper: ->(_) {}).call
      audit = saved_audit(@site)
      audit.update!(report: crawl)
      refute_includes crawl.to_json, "51.38234"

      post run_seo_workflows_path, params: { template: "E4" }
      follow_redirect!
      assert_select "li", text: /Storefront schema check.*Review mismatched fields: Map coordinates\./m
      assert_select "pre.schedule-draft", count: 0
      run = @site.seo_workflow_runs.sole
      saved_page = crawl.fetch("pages").find { |page| page["path"] == "/location" }
      saved_page.delete("local_business_evidence_version")
      saved_page["local_business_fingerprint"].except!(*SiteAudits::LocalBusinessMarkup::EXTENDED_FIELDS)
      audit.update!(report: crawl)
      patch refresh_draft_seo_workflow_path(run)
      follow_redirect!
      assert_select "li", text: /Run a fresh crawl to compare: Business type, Map coordinates, Opening hours\./m

      saved_page["structured_markup_present"] = false
      audit.update!(report: crawl)
      patch refresh_draft_seo_workflow_path(run)
      follow_redirect!
      assert_select "pre.schedule-draft", count: 1
      draft = run.reload.result.find { |row| row["draft"] }
      schema = JSON.parse(draft.fetch("draft"))
      assert_equal "MedicalClinic", schema["@type"]
      assert_equal [51.38123, -2.35912], schema.fetch("geo").values_at("latitude", "longitude")
      assert_equal ["Saturday"], schema.fetch("openingHoursSpecification").last.fetch("dayOfWeek")
      patch review_seo_workflow_path(run), params: { decision: "approve", revision: run.draft_revision }
      assert_equal "approved", run.reload.status
    end
  end

  test "current-period previews use only selected-site evidence and preserve reports" do
    travel_to Time.utc(2026, 11, 27, 10) do
      @site.keywords.create!(phrase: "garden clinic", preferred_url: "https://garden.example/location")
      audit = saved_audit(@site)
      audit.update!(report: { "pages" => [{ "path" => "/location", "issues" => ["missing_h1"] }] })
      other = Workspace.create!(name: "Other").sites.create!(name: "Other", host: "other.example", location: "Paris")
      [@site, other].zip([1, 99]).each do |site, count|
        site.source_snapshots.create!(provider: "DataForSEO", external_id: "M2-2026-11-22", title: "Provider aggregate",
          observed_on: Date.new(2026, 11, 27), scope: "Review sample", metrics: {
            "host" => site.host, "kind" => "review_activity", "period_on" => "2026-11-22", "state" => "captured",
            "records" => [{ "week_ending" => "2026-11-22", "new_reviews" => count, "new_one_star" => 0,
              "unanswered_low_rating" => 0, "complete_coverage" => true }]
          })
      end

      get setup_seo_workflows_path
      assert_select "#E4 a[href=?]", evidence_preview_seo_workflows_path(template: "E4"), text: "Preview current period"
      @membership.update!(role: "viewer")
      assert_no_difference ["SeoWorkflowRun.count", "SeoWorkflowNotification.count"] do
        get evidence_preview_seo_workflows_path(template: "E4")
        assert_response :success
        assert_select "p", text: /Current-period preview.*2026-10-01 to 2026-11-27/
        assert_select "li", text: /Missing main heading/
        assert_select "button", text: "Approve draft", count: 0
        get evidence_preview_seo_workflows_path(template: "R2")
        assert_response :success
        assert_select "li", text: /DataForSEO · Google reviews.*Week ending 2026-11-22: 1 new reviews/
        refute_includes response.body, "99 new reviews"
        get evidence_preview_seo_workflows_path(template: "E2")
        assert_response :not_found
      end

      @membership.update!(role: "owner")
      post run_seo_workflows_path, params: { template: "R1" }
      run = @site.seo_workflow_runs.find_by!(template_key: "R1")
      assert_equal Date.new(2026, 11, 22), run.period_on
      assert_equal "complete", run.status
      assert_equal ["Weekly performance summary", "DataForSEO · Google reviews"], run.result.pluck("source")
    end
  end

  test "workflow setup is readable for members and points owners at the correct import" do
    get setup_seo_workflows_path
    assert_response :success
    assert_select ".workflow-guide-task", count: 15
    assert_select "#M3", text: /Setup or evidence needed.*baseline/m
    assert_select "#M3 a[href=?]", seo_workflows_path(evidence: "profile_fields", anchor: "workflow-evidence")
    get seo_workflows_path(evidence: "profile_fields")
    assert_select "details[open] option[selected][value=profile_fields]"
    assert_select "code", text: "field,value"

    @membership.update!(role: "viewer")
    get setup_seo_workflows_path
    assert_response :success
    assert_select ".workflow-guide-task", count: 15
    assert_select "#M3 a", text: "Import business profile fields", count: 0
    assert_select "#P1 a[href=?]", prospect_audits_path, count: 0
  end

  private

  def upload_csv(kind, day, csv)
    Tempfile.create(["workflow-evidence", ".csv"]) do |file|
      file.write(csv)
      file.flush
      post import_evidence_seo_workflows_path, params: { kind: kind, observed_on: day,
        export: Rack::Test::UploadedFile.new(file.path, "text/csv") }
      assert_response :see_other
    end
  end

  def saved_audit(site)
    SiteAudit.create!(site: site, host: site.host, status: "complete", trigger_kind: "manual", finished_at: 1.day.ago)
  end
end
