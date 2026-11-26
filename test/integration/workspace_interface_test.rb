require "test_helper"

class WorkspaceInterfaceTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(email: "interface-owner@example.test", password: "my-long-test-password")
    @workspace = Workspace.create!(name: "Interface tests")
    @workspace.memberships.create!(user: @owner, role: "owner")
    @site = @workspace.sites.create!(name: "City Plumber", host: "plumber.example", location: "Norwich")
  end

  test "public catalogue reveals all seventeen methods without granting site access" do
    get login_path
    assert_select "#public-catalogue li", count: 17
    get public_catalogue_path, params: { q: "LOCALFALCON" }
    assert_select "article h2", text: "Local Falcon", count: 1
    assert_select "article .badge", text: "Read existing reports"
    get integrations_path
    assert_redirected_to login_path
  end

  test "provider setup and settings keep the correct workspace section selected" do
    login_as(@owner)
    {search_console_path => integrations_path, analytics_path => integrations_path,
     local_falcon_connection_path => integrations_path, wording_setting_path => actions_path,
     project_tasks_path => project_tasks_path, source_snapshots_path => source_snapshots_path}.each do |page, section|
      get page
      assert_response :success
      assert_select "nav.primary-nav a[aria-current=page]", count: 1
      assert_select "nav.primary-nav a[aria-current=page][href=?]", section
      assert_select "main#main[tabindex='-1']", count: 1
      assert_select "main#main nav.primary-nav", count: 0
    end
  end

  test "save replace and remove an allowed report link only for this site" do
    login_as(@owner)
    url = "https://www.localfalcon.com/reports/view/report_B-4/"
    patch integration_path("local-falcon"), params: { site_report_link: { url: url } }
    assert_redirected_to integration_path("local-falcon")
    follow_redirect!
    assert_select "a[href=?][rel~=noreferrer]", url

    invalid = ["http://localfalcon.com/reports/view/id", "https://localfalcon.com.fake.test/reports/view/id",
               "https://localfalcon.com:444/reports/view/id", "https://localfalcon.com/other",
               "https://guest@localfalcon.com/reports/view/id", "https://localfalcon.com/reports/view/id?return=1"]
    invalid.each do |unsafe|
      patch integration_path("local-falcon"), params: { site_report_link: { url: unsafe } }
      assert_response :unprocessable_entity
      assert_equal url, @site.site_report_links.sole.url
    end

    other = @workspace.sites.create!(name: "Other site", host: "other.example", location: "London")
    post select_site_path(other)
    get integration_path("local-falcon")
    assert_select "a[href=?]", url, count: 0
    patch integration_path("local-falcon"), params: { remove: "1" }
    assert @site.site_report_links.exists?
    post select_site_path(@site)
    patch integration_path("local-falcon"), params: { remove: "1" }
    assert_empty @site.site_report_links
  end

  test "viewers can inspect services but cannot change reports, enrol keywords or import" do
    viewer = User.create!(email: "interface-viewer@example.test", password: "my-long-test-password")
    @workspace.memberships.create!(user: viewer, role: "viewer")
    keyword = Tracking::Enrollment.call(site: @site, phrase: "warm water")
    login_as(viewer)
    get integration_path("local-falcon")
    assert_response :success
    assert_select "input[type=url]", count: 0
    patch integration_path("local-falcon"), params: { remove: "1" }
    assert_response :forbidden
    post keywords_path, params: { keyword: { phrase: "boiler repair" } }
    assert_response :forbidden
    get new_keyword_rank_import_path(keyword)
    assert_response :forbidden
    assert_equal 1, @site.keywords.count
  end

  test "manager can import one observation and inspect independent device rankings" do
    login_as(@owner)
    post keywords_path, params: { keyword: { phrase: "plumber norwich" } }
    assert_redirected_to rankings_path
    keyword = @site.keywords.sole
    settings = keyword.tracking_series.find_by!(device: "mobile").settings
    payload = settings.slice("keyword", "location", "language", "device", "host", "depth", "source")
    payload.merge!("captured_at" => Time.current.iso8601, "items" => [
      { "type" => "organic", "rank_group" => 1, "url" => "https://plumber.example/services" }
    ])
    post keyword_rank_imports_path(keyword), params: { rank_import: { device: "mobile", payload: payload.to_json } }
    assert_redirected_to keyword_path(keyword, device: "mobile")
    follow_redirect!
    assert_select "td", text: "#1"
    get rankings_path, params: { device: "desktop" }
    assert_select "tbody td strong", text: "No reading"
    get rankings_path, params: { device: "mobile" }
    assert_select "tbody td strong", text: "#1"
  end

  private

  def login_as(user)
    post login_path, params: { session: { email: user.email, password: "my-long-test-password" } }
    assert_redirected_to dashboard_path
  end
end
