require "test_helper"

class VisibilityOverviewTest < ActionDispatch::IntegrationTest
  setup do
    workspace = Workspace.create!(name: "Visibility workspace")
    @site = workspace.sites.create!(name: "Bakery", host: "bakery.example", location: "York")
    user = User.create!(email: "visibility-owner@example.test", password: "secure-example-password")
    workspace.memberships.create!(user: user, role: "owner")
    post login_path, params: { session: { email: user.email, password: "secure-example-password" } }
    @property = "sc-domain:bakery.example"
    @finish = Date.new(2026, 4, 30)
    @stats = { "clicks" => 15, "impressions" => 120, "ctr" => 0.125, "position" => 7.8 }
    @report = {"property" => @property, "search_type" => "web", "data_state" => "final", "country_scope" => "All countries",
      "current" => period(@finish, @stats), "previous" => period(@finish - 28, @stats.merge("clicks" => 10)),
      "performance_days" => [{"date" => "2026-04-03", "clicks" => 0, "impressions" => 3},
        {"date" => "2026-04-05", "clicks" => 15, "impressions" => 117}]}
  end

  test "overview charts break at unreported days and retain actual zero readings" do
    connection = @site.create_search_console_connection!(status: "connected", property: @property, report: @report)
    get dashboard_path
    assert_response :success
    assert_select "h1", "Visibility overview"
    assert_select "nav.primary-nav a[aria-current=page][href=?]", dashboard_path
    assert_select ".daily-line", count: 2
    assert_select ".daily-point", count: 2
    assert_select ".overview-values tbody tr", count: 28
    assert_select ".overview-values td", text: /No reported value/, count: 26
    assert_select ".overview-values td", text: "0", count: 1
    assert_select ".overview-kpi", text: /Up 50% vs prior 28 days/
    get dashboard_path(metric: "impressions")
    assert_select "#search-plot-title", "Daily search impressions"
    assert_select ".overview-values td", text: "117"
    connection.update!(status: "reconnect")
    get dashboard_path
    assert_select ".daily-line", count: 0
    assert_select ".overview-kpi", text: /Up 50%/, count: 0
    connection.update!(status: "connected", property: "sc-domain:different.example")
    get dashboard_path
    assert_select ".daily-point", count: 0
  end

  test "existing reports retain their totals and filtered ranking bookmarks retain their purpose" do
    @site.create_search_console_connection!(status: "delayed", property: @property, report: @report.except("performance_days"))
    get root_path
    assert_response :success
    assert_select ".overview-kpi strong", text: "120"
    assert_select ".daily-point", count: 0
    assert_select "#search-chart", text: /sync was delayed/
    get dashboard_path(source: "local", device: "desktop", day: "2026-04-30")
    assert_redirected_to rankings_path(source: "local", device: "desktop", day: "2026-04-30")
  end

  test "chart filters update their shared frame and retain the selected scan and other chart" do
    @site.create_search_console_connection!(status: "connected", property: @property, report: @report)
    scan = @site.source_snapshots.create!(provider: "Local Falcon", external_id: "0123456789abcde",
      keyword: "local bakery", title: "Scan", observed_on: @finish, scope: "Google Maps",
      source_url: "https://app.localfalcon.com/reports/view/0123456789abcde", metrics: {grid_size: 7, solv: 50})
    get dashboard_path(metric: "impressions", map_scan: scan.external_id)
    desktop_link = css_select("#rank-chart-desktop").sole
    assert_equal "overview-filters", desktop_link["data-turbo-frame"]
    assert_equal dashboard_path(metric: "impressions", map_scan: scan.external_id, rank_device: "desktop", anchor: "rank-distribution"), desktop_link["href"]
    get desktop_link["href"], headers: {"Turbo-Frame" => "overview-filters"}
    assert_response :success
    assert_select "turbo-frame#overview-filters[data-turbo-action=advance][target=_top][data-filter-frame=?]", @site.id.to_s do
      assert_select "#rank-chart-desktop[aria-current=true]"
      assert_select "#search-chart-clicks[href=?]", dashboard_path(metric: "clicks", rank_device: "desktop", map_scan: scan.external_id, anchor: "search-chart")
      assert_select ".lf-picker input[name=rank_device][value=desktop]"
      assert_select ".lf-picker input[name=metric][value=impressions]"
      assert_select ".lf-picker option[selected][value=?]", scan.external_id
    end
  end

  private

  def period(finish, metrics)
    {"start" => (finish - 27).iso8601, "end" => finish.iso8601, "metrics" => metrics}
  end
end
