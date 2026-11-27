require "test_helper"

class SeoWorkspaceDashboardTest < ActionDispatch::IntegrationTest
  setup do
    @password = "example-seo-workflows-password"
    @workspace = Workspace.create!(name: "Workflow workspace")
    @user = User.create!(email: "workflow-owner@example.test", password: @password)
    @membership = @workspace.memberships.create!(user: @user, role: "owner")
    @site = @workspace.sites.create!(name: "River Plumbing", host: "river-plumbing.example", location: "Bath",
      time_zone: "Europe/London", rank_country_code: "GB", weekly_site_audit_enabled: true)
  end

  test "overview and workflow lead to setup and templates without requesting a provider run" do
    get seo_workflow_overview_path
    assert_redirected_to login_path
    sign_in

    assert_no_enqueued_jobs do
      get dashboard_path
      assert_response :success
      assert_select ".seo-queue .seo-review", count: 3
      assert_select ".seo-queue a[href=?]", new_keyword_path
      assert_select ".seo-queue a[href=?]", search_console_path
      assert_select ".seo-queue a[href=?]", local_falcon_connection_path
      assert_select ".seo-tool-grid a[href=?]", seo_workflow_overview_path(anchor: "templates")
      get seo_workflow_overview_path
      assert_response :success
      assert_select "nav.primary-nav a[aria-current=page][href=?]", seo_workflow_overview_path
      assert_select "[data-workflow-key='search-console'] .seo-status", text: "Not connected"
      assert_select "[data-workflow-key='rankings'] a[href=?]", new_keyword_path
      assert_select "#templates a[href=?]", seo_workflows_path(anchor: "task-templates")
      assert_select "#templates a[href=?]", assistant_path(anchor: "question-templates")
      assert_select "#templates a[href=?]", actions_path(anchor: "keyword-recommendations")
      assert_select "#templates a[href=?]", competing_pages_path
    end

    @membership.update!(role: "viewer")
    get seo_workflow_overview_path
    assert_response :success
    assert_select ".seo-workflows a[href=?]", new_keyword_path, count: 0
    assert_select ".seo-workflows a[href=?]", new_project_import_path, count: 0
    assert_select "#templates a[href=?]", assistant_path(anchor: "review-heading")
    get dashboard_path
    assert_select ".seo-queue", text: /Ask a site manager to add your first search term/
  end

  test "site work shows real evidence dates and leaves other sites and stale scopes out" do
    travel_to Time.utc(2026, 6, 4, 15) do
      other_site = @workspace.sites.create!(name: "Another site", host: "other.example", location: "York")
      task(other_site, "Other site task", "critical")
      task(@site, "Closed task", "critical", working_status: "completed")
      priority = task(@site, "Verify the service enquiry form", "high", working_status: "in_progress")
      task(@site, "Check the home page heading", "low")
      keyword = Tracking::Enrollment.call(site: @site, phrase: "bath plumber")
      action = keyword.tracking_series.first.keyword_actions.create!(kind: "page_match", status: "open",
        title: "Check which page is ranking", description: "Review the saved keyword evidence.",
        observed_on: Date.new(2026, 6, 4))
      @site.create_search_console_connection!(status: "connected", property: "sc-domain:#{@site.host}")
      finding = finding_for(keyword, country: "GBR")
      stale = finding_for(keyword, country: "USA")
      SiteAudit.create!(site: @site, host: @site.host, status: "complete", trigger_kind: "manual",
        created_at: Time.utc(2026, 6, 3, 10), finished_at: Time.utc(2026, 6, 3, 10, 5))

      sign_in
      get dashboard_path
      assert_response :success
      assert_select ".seo-queue a[href=?]", project_task_path(priority)
      assert_select ".seo-queue a[href=?]", action_draft_path(action)
      assert_select ".seo-queue a[href=?]", competing_page_path(finding)
      assert_no_match(/Other site task|Closed task/, response.body)

      get seo_workflow_overview_path, params: { site_id: other_site.id }
      assert_response :success
      assert_select "#act time[datetime='2026-06-04']", count: 2
      assert_select "#act time[datetime='2026-05-31']", text: "31 May 2026"
      assert_select "#act a[href=?]", competing_page_path(stale), count: 0
      assert_select "#act a[href=?]", project_tasks_path, text: "View all 2"
      assert_select "[data-workflow-key='site_audit']" do
        assert_select "time", text: "3 Jun 2026, 11:05 BST"
        assert_select "time", text: "10 Jun 2026, 11:00 BST"
      end

      post select_site_path(other_site)
      get seo_workflow_overview_path
      assert_response :success
      assert_select "#act", text: /Other site task/
      assert_no_match(/Verify the service enquiry form|Check which page is ranking/, response.body)
      assert_select "#act a[href=?]", competing_page_path(finding), count: 0
    end
  end

  test "a pending SEO report appears with its deadline and gives viewers a read-only route" do
    travel_to Time.utc(2026, 6, 4, 8) do
      run = @site.seo_workflow_runs.create!(template_key: "R2", site_host: @site.host,
        period_on: Date.new(2026, 5, 31), status: "awaiting_approval", result: [])
      @site.seo_workflow_schedules.create!(template_key: "R2")
      missing = @site.seo_workflow_runs.create!(template_key: "M2", site_host: @site.host,
        period_on: Date.new(2026, 5, 31), status: "missing_evidence")
      @site.seo_workflow_runs.create!(template_key: "M1", site_host: "previous.example",
        period_on: Date.new(2026, 5, 31), status: "awaiting_approval")
      sign_in
      get dashboard_path
      assert_select ".seo-queue a[href=?]", seo_workflow_path(run), text: "Review draft"
      assert_select ".seo-queue time", text: "7 Jun 2026, 09:00 BST"
      assert_select ".seo-queue a[href=?]", seo_workflow_path(missing), text: "See what’s needed"
      get seo_workflow_path(missing)
      assert_select "a[href=?]", setup_seo_workflows_path(anchor: "M2")
      get seo_workflows_path
      assert_select "#awaiting-approval a[href=?]", seo_workflow_path(run)
      assert_select "#awaiting-approval li", count: 1
      assert_select "#task-R2 time", text: "1 Jul 2026, 08:00 BST"

      @membership.update!(role: "viewer")
      get dashboard_path
      assert_select ".seo-queue a[href=?]", seo_workflow_path(run), text: "View draft"
      get seo_workflows_path
      assert_select "#task-templates form", count: 0
      assert_select "#workflow-evidence", count: 0
      run.update_column(:updated_at, 3.days.ago)
      get dashboard_path
      assert_select ".seo-queue a[href=?]", seo_workflow_path(run), count: 0
    end
  end

  private

  def sign_in
    post login_path, params: { session: { email: @user.email, password: @password } }
    assert_redirected_to dashboard_path
  end

  def task(site, title, priority, working_status: nil)
    site.project_tasks.create!(external_id: SecureRandom.uuid, title: title, status: "to_do",
      priority: priority, working_status: working_status)
  end

  def finding_for(keyword, country:)
    SiteFinding.create!(site: @site, keyword: keyword, kind: "competing_pages", level: "review",
      fingerprint: "workflow-#{country}", evidence: { "country" => country, "property" => "sc-domain:#{@site.host}",
        "device" => "mobile", "clicks" => { "current_end" => "2026-05-31" } })
  end
end
