require "test_helper"

class SiteAuditsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(email: "audit-owner@example.test", password: "long-test-password")
    workspace = Workspace.create!(name: "Audit team")
    @member = workspace.memberships.create!(user: @user, role: "owner")
    @site = workspace.sites.create!(name: "Tenant clinic", host: "clinic.test", location: "Bristol")
    post login_path, params: {session: {email: @user.email, password: "long-test-password"}}
  end

  test "owner can start a small crawl and opt in and out of weekly runs without a data provider" do
    get site_audit_path
    assert_response :success
    assert_select "h1", "Site audit"
    assert_select "form[action=?] button", site_audit_path, text: /Run crawl/
    assert_select "a[href=?]", search_console_path, text: "Set up Search Console"
    assert_not @site.weekly_site_audit_enabled?
    assert_difference("SiteAudit.count", 1) do
      assert_enqueued_jobs 1, only: SiteAuditJob do
        2.times { post site_audit_path }
      end
    end
    follow_redirect!
    assert_response :success
    assert_select ".audit-state", "Queued"
    [true, false].each do |enabled|
      patch schedule_site_audit_path, params: {site: {weekly_site_audit_enabled: enabled ? "1" : "0"}}
      assert_redirected_to site_audit_path
      assert_equal enabled, @site.reload.weekly_site_audit_enabled?
    end
  end

  test "managers and viewers can inspect findings but cannot crawl or update the schedule" do
    %w[manager viewer].each do |role|
      @member.update!(role: role)
      get site_audit_path
      assert_response :success
      assert_select "form[action=?]", site_audit_path, count: 0
      post site_audit_path
      assert_response :forbidden
      patch schedule_site_audit_path, params: {site: {weekly_site_audit_enabled: "1"}}
      assert_response :forbidden
      assert_not @site.reload.weekly_site_audit_enabled?
    end
  end

  test "findings show the measured page, advice and both ends of a broken link in the selected crawl" do
    report = {"summary" => {"pages_checked" => 2, "html_pages" => 1, "pages_with_issues" => 2, "redirects" => 0},
      "issues" => [{"code" => "broken_link", "label" => "Link leads to an HTTP error", "advice" => "Check the target.", "count" => 1, "paths" => ["/good"]}],
      "pages" => [{"path" => "/good", "url" => "https://clinic.test/good", "status" => 200, "title" => "Clinic", "h1_count" => 1,
        "issues" => ["broken_link"], "broken_links" => ["/gone"]}, {"path" => "/gone", "status" => 404, "issues" => ["http_error"]}]}
    saved = SiteAudit.create!(site: @site, host: @site.host, report: report, status: "complete", finished_at: 2.days.ago)
    SiteAudit.create!(site: @site, host: @site.host, status: "queued")
    get site_audit_path(run: saved)
    assert_response :success
    assert_select ".audit-findings", /Check the target/
    assert_select ".audit-findings a[href='https://clinic.test/good']"
    assert_select ".audit-findings a[href='https://clinic.test/gone']"
    assert_select ".audit-pages td", "404"
    assert_select ".audit-history li", count: 2

    other = Workspace.create!(name: "Another team").sites.create!(host: "other.test", name: "Other", location: "London")
    other_run = SiteAudit.create!(site: other, host: other.host, status: "complete")
    get site_audit_path(run: other_run)
    assert_response :not_found
  end

  test "Google reports show proper periods, zero values, source dates and property scoped links" do
    metrics = {"clicks" => 0, "impressions" => 300, "ctr" => 0.0, "position" => 4.2}
    report = {"property" => "sc-domain:clinic.test", "search_type" => "web", "data_state" => "final",
      "current" => {"start" => "2026-10-24", "end" => "2026-11-20", "metrics" => metrics},
      "previous" => {"start" => "2026-09-26", "end" => "2026-10-23", "metrics" => nil},
      "sitemaps" => {"status" => "available", "checked_at" => "2026-11-24T09:00:00Z",
        "last_downloaded" => "2026-11-23T09:00:00Z", "count" => 2, "errors" => 0, "warnings" => 3, "pending" => 1}}
    c = @site.create_search_console_connection!(property: report["property"], status: "delayed", report: report)
    get site_audit_path
    assert_response :success
    assert_match "20 Nov 2026", response.body
    assert_match "Google sync is delayed", response.body
    assert_select ".audit-sitemap dd", text: "2"
    assert_select ".audit-metrics dd", text: "0.0%"
    assert_select ".audit-metrics dd", text: "Previously Unavailable"
    assert_select "a[href=?]", "https://search.google.com/search-console/settings/crawl-stats?resource_id=sc-domain%3Aclinic.test"

    c.update!(property: "sc-domain:another.test")
    get site_audit_path
    assert_select ".audit-sitemap", count: 0
    assert_select ".audit-metrics", count: 0
    c.update!(property: report["property"], status: "reconnect")
    get site_audit_path
    assert_select ".audit-sitemap", count: 0
    assert_match "Reconnect Google", response.body
  end
end
