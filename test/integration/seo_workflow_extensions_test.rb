require "test_helper"

class SeoWorkflowExtensionsTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "seo-extensions@example.test", email_verified_at: Time.current,
      password: "long-seo-test-password")
    @workspace = Workspace.create!(name: "Workflow extensions")
    @membership = @workspace.memberships.create!(user: @user, role: "owner")
    @site = @workspace.sites.create!(name: "Heating company", host: "heating.example", location: "Bath")
    post login_path, params: { session: { email: @user.email, password: "long-seo-test-password" } }
    assert_redirected_to dashboard_path
  end

  test "imports, compares and displays every added single-site template" do
    travel_to Time.utc(2026, 6, 1, 10) do
      comparisons = {
        "M3" => ["profile_fields", "field,value\ncategory,Plumber\n", "field,value\ncategory,Heating engineer\n",
          "2026-05-31", "2026-06-01", /Plumber to Heating engineer/],
        "M4" => ["lsa_rankings", "query,market,position\nHeating,Bath,2\n", "query,market,position\nHeating,Bath,4\n",
          "2026-05-24", "2026-05-31", /outside the top three/],
        "M5" => ["ai_visibility", "engine,prompt,market,mentioned,cited\nchatgpt,Heating,Bath,false,false\n",
          "engine,prompt,market,mentioned,cited\nchatgpt,Heating,Bath,true,false\n", "2026-04-30", "2026-05-31", /Mention: no → yes/],
        "P2" => ["competitors", "business,query,market,map_position,review_count,active_ad\nFixture,Heating,Bath,3,10,false\n",
          "business,query,market,map_position,review_count,active_ad\nFixture,Heating,Bath,2,11,true\n",
          "2026-04-30", "2026-05-31", /Maps position 3 → 2/]
      }

      comparisons.each do |task, (kind, previous, latest, before, after, expected)|
        upload(kind, previous, before)
        upload(kind, latest, after)
        run_task(task)
        assert_select "li", text: expected
      end

      drafts = {
        "E1" => ["post_brief", "service,approved_detail\nHeating,We check boiler efficiency\n", /We check boiler efficiency/],
        "E2" => ["review_queue", "review_ref,rating\nfixture-2,2\n", /Please contact us directly/]
      }
      drafts.each do |task, (kind, csv, expected)|
        upload(kind, csv, "2026-05-31")
        run_task(task)
        assert_select "li", text: expected
        assert_select "button", text: "Approve draft"
      end

      upload("prospect", "target_host,check,observation\nprospect.example,website,Title found\n", "2026-06-01")
      run_task("P1")
      assert_select "li", text: /prospect\.example.*Title found/
      post schedule_seo_workflows_path, params: { template: "P1", enabled: "1" }
      assert_response :unprocessable_entity
    end
  end

  test "R3 rolls up monthly location evidence, flags systemic issues and exports scoped structured data" do
    travel_to Time.utc(2026, 6, 1, 8, 15) do
      @site.update!(time_zone: "Europe/London")
      second = @workspace.sites.create!(name: "Second location", host: "second.example", location: "Bristol",
        seo_workflow_rollup_enabled: true)
      third = @workspace.sites.create!(name: "Third location", host: "third.example", location: "Bath",
        seo_workflow_rollup_enabled: true)
      missing = @workspace.sites.create!(name: "Missing location", host: "missing.example", location: "York",
        seo_workflow_rollup_enabled: true)
      foreign = Workspace.create!(name: "Private").sites.create!(name: "External location", host: "external.example",
        location: "Bristol", seo_workflow_rollup_enabled: true)
      patch rollup_seo_workflows_path, params: { enabled: "1" }

      finish = Date.new(2026, 5, 31)
      reports = [@site, second, third, foreign].to_h do |site|
        rollup_review_fixture(site, finish)
        SiteAudit.create!(site: site, host: site.host, status: "complete", trigger_kind: "manual", finished_at: 1.day.ago)
        report = SeoWorkflowRun.generate!(site: site, template: SeoWorkflows::Catalogue.fetch("R2"), day: finish)
        [site, report]
      end
      rollup_map_fixture(@site)
      schedule = @site.seo_workflow_schedules.create!(template_key: "R3")
      schedule.run_due!(now: Time.current)
      assert_not @site.seo_workflow_runs.exists?(template_key: "R3")

      schedule.run_due!(now: Time.utc(2026, 6, 1, 9))
      rollup = @site.seo_workflow_runs.find_by!(template_key: "R3")
      assert_equal "complete", rollup.status
      assert_equal "attention", SeoWorkflowNotification.where(seo_workflow_run: rollup).sole.kind
      get seo_workflow_path(rollup)
      assert_select "p", /Partial.*3 of 4/
      assert_select "tbody tr:first-child td", text: "Urgent"
      assert_select "tbody tr", text: /Missing location.*Monthly report missing/m
      assert_select "tbody tr", text: /Heating company.*ARP 7.0.*SoLV 50.0%.*10 new reviews/m
      assert_select "li", text: /Unanswered low-rated reviews.*3 of 4 locations/
      assert_no_match(/External location/, response.body)

      get export_evidence_seo_workflows_path
      entry = JSON.parse(response.body).fetch("reports").find { |run| run["template"] == "R3" }.fetch("rollup")
      assert_equal "partial", entry.fetch("coverage")
      assert_equal 3, entry.fetch("brand_patterns").fetch("reviews_unanswered")
      assert_equal 4, entry.fetch("locations").size
      location = entry.fetch("locations").find { |row| row["host"] == @site.host }
      assert_equal(-15.0, location.dig("maps", "solv_change"))
      assert_equal "down", location.dig("reviews", "direction")
      assert_equal 4.5, location.dig("reviews", "rating")
      assert_equal seo_workflow_path(reports.fetch(@site)), location.fetch("report_path")
      assert_no_match(/External location/, response.body)

      # A report that arrives after the schedule can close the same rollup's coverage gap.
      SiteAudit.create!(site: missing, host: missing.host, status: "complete", trigger_kind: "manual", finished_at: 1.day.ago)
      SeoWorkflowRun.generate!(site: missing, template: SeoWorkflows::Catalogue.fetch("R2"), day: finish)
      run_task("R3")
      assert_select "p", /Complete.*4 of 4/
      assert_equal 1, @site.seo_workflow_runs.where(template_key: "R3").count

      second.update!(seo_workflow_rollup_enabled: false)
      get seo_workflow_path(rollup)
      assert_select "tbody tr", text: /Second location/, count: 0
      assert_select "h3", text: "Location-specific issues"
      get export_evidence_seo_workflows_path
      refute_includes response.body, "second.example"
      post open_rollup_location_seo_workflows_path, params: { rollup_id: rollup.id, report_id: reports.fetch(second).id }
      assert_response :not_found
      post open_rollup_location_seo_workflows_path, params: { rollup_id: rollup.id, report_id: reports.fetch(foreign).id }
      assert_response :not_found
      post open_rollup_location_seo_workflows_path, params: { rollup_id: rollup.id, report_id: reports.fetch(third).id }
      assert_redirected_to seo_workflow_path(reports.fetch(third))
      follow_redirect!
      assert_response :success
    end
  end

  test "approved notifications deliver once, remind and expire automatically" do
    ActionMailer::Base.deliveries.clear
    travel_to Time.utc(2026, 6, 1, 10) do
      patch notifications_seo_workflows_path, params: { enabled: "1" }
      assert_redirected_to seo_workflows_path
      SiteAudit.create!(site: @site, host: @site.host, status: "complete", trigger_kind: "manual", finished_at: 1.day.ago)
      run_task("R2")
      2.times { SeoWorkflowNotificationsJob.perform_now }
      assert_equal ["Searchdesk · Review requested"], ActionMailer::Base.deliveries.map(&:subject)
      assert_equal [@user.email], ActionMailer::Base.deliveries.first.to
      assert_no_match(/Heating company/, ActionMailer::Base.deliveries.first.body.decoded)
    end
    travel_to Time.utc(2026, 6, 3, 11) do
      2.times { SeoWorkflowNotificationsJob.perform_now }
      assert_equal 1, SeoWorkflowNotification.where(kind: "reminder").count
      assert_equal "Searchdesk · Review reminder", ActionMailer::Base.deliveries.last.subject
    end
    travel_to Time.utc(2026, 6, 4, 11) do
      SeoWorkflowNotificationsJob.perform_now
      assert_equal "expired", @site.seo_workflow_runs.sole.status
      assert_equal "Searchdesk · Draft expired", ActionMailer::Base.deliveries.last.subject
    end
  ensure
    ActionMailer::Base.deliveries.clear
  end

  test "outbound preference and owner access are checked again at dispatch" do
    ActionMailer::Base.deliveries.clear
    patch notifications_seo_workflows_path, params: { enabled: "1" }
    travel_to Time.utc(2026, 6, 1, 10) do
      SiteAudit.create!(site: @site, host: @site.host, status: "complete", trigger_kind: "manual", finished_at: 1.day.ago)
      run_task("R2")
      @membership.update!(role: "manager")
      SeoWorkflowNotificationsJob.perform_now
      assert_empty ActionMailer::Base.deliveries
      assert_equal "cancelled", SeoWorkflowNotification.sole.email_status
    end
  end

  test "client email requires recipient preview and explicit confirmation before one delivery" do
    original = ENV["SEO_WORKFLOW_CLIENT_EMAIL_ENABLED"]
    ENV["SEO_WORKFLOW_CLIENT_EMAIL_ENABLED"] = "true"
    ActionMailer::Base.deliveries.clear
    travel_to Time.utc(2026, 6, 1, 10) do
      SiteAudit.create!(site: @site, host: @site.host, status: "complete", trigger_kind: "manual", finished_at: 1.day.ago)
      run_task("R2")
      run = @site.seo_workflow_runs.sole
      post preview_delivery_seo_workflow_path(run), params: { recipient: "client@example.test" }
      assert_response :conflict
      patch review_seo_workflow_path(run), params: { decision: "approve" }
      post preview_delivery_seo_workflow_path(run), params: { recipient: "client@example.test" }
      follow_redirect!
      assert_select "strong", text: "client@example.test"
      delivery = run.reload.report_delivery
      assert_equal "preview", delivery.status
      SeoWorkflowNotificationsJob.perform_now
      assert_empty ActionMailer::Base.deliveries

      patch confirm_delivery_seo_workflow_path(run), params: { delivery_id: delivery.id }
      assert_response :see_other
      2.times { SeoWorkflowNotificationsJob.perform_now }
      mail = ActionMailer::Base.deliveries.sole
      assert_equal ["client@example.test"], mail.to
      assert_match(/Website crawl/, mail.body.decoded)
      assert_equal "sent", delivery.reload.status
      assert_equal "delivered", run.reload.status
      assert_equal 1, SeoWorkflowNotification.where(kind: "delivered").count
    end
  ensure
    ENV["SEO_WORKFLOW_CLIENT_EMAIL_ENABLED"] = original
    ActionMailer::Base.deliveries.clear
  end

  test "citation and quarterly reports feed a private bundle scoped to the current site" do
    travel_to Time.utc(2026, 7, 1, 10) do
      upload("citations", "directory,url,status\nFixture,https://fixture.example,listed\n", "2026-06-30")
      SiteAudit.create!(site: @site, host: @site.host, status: "complete", trigger_kind: "manual", finished_at: 1.day.ago)
      run_task("E3")
      assert_select "li", text: /Directory rows: 1/
      run_task("R4")
      assert_select "button", text: "Approve draft"
      patch review_seo_workflow_path(@site.seo_workflow_runs.find_by!(template_key: "R4")), params: { decision: "approve" }

      other = @workspace.sites.create!(name: "Other location", host: "other.example", location: "London")
      SourceSnapshot.create!(site: other, provider: SeoWorkflows::EvidenceImport::PROVIDER, external_id: "private-source",
        title: "Other location private source", observed_on: Date.current, scope: "Other",
        metrics: { "host" => other.host, "kind" => "manual" })
      get export_evidence_seo_workflows_path
      assert_response :success
      assert_includes response.headers.fetch("Cache-Control"), "no-store"
      bundle = JSON.parse(response.body)
      assert_equal @site.host, bundle.fetch("site_host")
      assert_equal %w[E3 R4], bundle.fetch("reports").map { |report| report.fetch("template") }.sort
      refute_includes response.body, "private-source"
      @membership.update!(role: "viewer")
      get export_evidence_seo_workflows_path
      assert_response :forbidden
    end
  end

  private

  def rollup_review_fixture(site, finish)
    prior = [5, 12, 19, 26].map { |day| Date.new(2026, 4, day) }.drop(1)
    current = [10, 17, 24, 31].map { |day| Date.new(2026, 5, day) }
    weeks = (prior + current).map do |day|
      previous = day.month == 4
      { "week_ending" => day.iso8601, "new_reviews" => previous ? 5 : { 10 => 1, 17 => 2, 24 => 3, 31 => 4 }.fetch(day.day),
        "average_rating" => 4.5, "new_one_star" => 0, "unanswered_low_rating" => day == finish ? 1 : 0 }
    end
    site.source_snapshots.create!(provider: SeoWorkflows::EvidenceImport::PROVIDER, external_id: "r3-reviews",
      title: "Weekly review activity", observed_on: Date.new(2026, 6, 1), scope: "Private fixture",
      metrics: { "kind" => "review_activity", "host" => site.host, "records" => weeks })
  end

  def rollup_map_fixture(site)
    place = "ChIJrollupfixture"
    site.create_local_falcon_connection!(place_id: place, verified_name: site.name, synced_at: Time.current)
    [Date.new(2026, 4, 29), Date.new(2026, 5, 30)].each_with_index do |day, index|
      reference = "abcd0000000000#{index + 1}"
      site.source_snapshots.create!(provider: "Local Falcon", external_id: reference, title: "Maps scan",
        observed_on: day, keyword: "heating repair", scope: "Existing Google Maps scan for #{site.host}.",
        metrics: { "place_id" => place, "grid_size" => 1, "arp" => 6 + index, "solv" => 65 - 15 * index },
        map_grid: { "place_id" => place, "report_key" => reference, "keyword" => "heating repair",
          "grid_size" => 1, "date" => day.iso8601, "radius" => 1, "unit" => "mi",
          "points" => [{ "lat" => 51.0, "lng" => -0.1, "rank" => 6 + index }] })
    end
  end

  def upload(kind, csv, observed_on)
    Tempfile.create(["signal", ".csv"]) do |file|
      file.write(csv)
      file.flush
      post import_evidence_seo_workflows_path, params: { kind: kind, observed_on: observed_on,
        export: Rack::Test::UploadedFile.new(file.path, "text/csv") }
      assert_redirected_to source_snapshot_path(@site.source_snapshots.order(:id).last)
    end
  end

  def run_task(key)
    post run_seo_workflows_path, params: { template: key }
    assert_redirected_to seo_workflow_path(@site.seo_workflow_runs.find_by!(template_key: key))
    follow_redirect!
    assert_response :success
  end
end
