require "test_helper"

class SchedulesTest < ActionDispatch::IntegrationTest
  setup do
    @password = "long-schedule-test-password"
    @user = User.create!(email: "schedule-owner@example.test", password: @password)
    workspace = Workspace.create!(name: "Schedule workspace")
    @membership = workspace.memberships.create!(user: @user, role: "owner")
    @site = workspace.sites.create!(name: "Garden clinic", host: "garden.example", location: "Bath",
      time_zone: "Europe/London", weekly_site_audit_enabled: true)
  end

  test "weekly crawl history and eligibility are distinct and use the site time zone" do
    travel_to Time.utc(2026, 6, 4, 15, 0) do
      requested = Time.utc(2026, 6, 3, 10, 31)
      SiteAudit.create!(site: @site, host: @site.host, status: "complete", trigger_kind: "manual",
        created_at: requested, started_at: requested + 1.minute, finished_at: requested + 5.minutes)
      sign_in
      get schedules_path
      assert_response :success
      assert_select "nav.primary-nav a[aria-current=page][href=?]", schedules_path
      assert_select "h1", "Schedules"
      assert_select ".rank-intro", /Garden clinic.*Europe\/London/
      assert_select ".schedule-row[data-schedule-key=site_audit]" do
        assert_select "dt", text: "Frequency"
        assert_select "dt", text: "Last run"
        assert_select "time", text: "3 Jun 2026, 11:36 BST"
        assert_select "time", text: "10 Jun 2026, 11:31 BST"
        assert_select "a[href=?]", site_audit_path
      end
      assert_select ".schedule-row[data-schedule-key=search-console]", /Not connected/
    end
  end

  test "all site members can read schedules while only owners see background check details" do
    SolidQueue::RecurringTask.insert_all!([{key: "site_audit_recovery", schedule: "every 10 minutes",
      class_name: "SiteAuditRecoveryJob"}])
    get schedules_path
    assert_redirected_to login_path
    sign_in
    get schedules_path
    assert_response :success
    assert_select "details.schedule-checks tbody th", text: "Site audit scheduling and recovery"
    %w[viewer manager].each do |role|
      @membership.update!(role: role)
      get schedules_path
      assert_response :success
      assert_select "details.schedule-checks", count: 0
      assert_select ".schedule-row a[href=?]", site_audit_path
      assert_select ".schedule-view form", count: 0
    end
  end

  test "a query parameter cannot read the crawl timings of a different site" do
    other = Workspace.create!(name: "Different workspace").sites.create!(name: "Aardvark", host: "other.example", location: "Paris")
    SiteAudit.create!(site: other, host: other.host, status: "complete", finished_at: Time.utc(2025, 12, 31, 18))
    sign_in
    get schedules_path, params: { site_id: other.id }
    assert_response :success
    assert_select ".schedule-row[data-schedule-key=site_audit]" do
      assert_select "time", count: 0
      assert_select "dd", text: /No recorded crawl/
    end
    assert_no_match(/other\.example/, response.body)
  end

  private

  def sign_in
    post login_path, params: { session: { email: @user.email, password: @password } }
    assert_redirected_to dashboard_path
  end
end
