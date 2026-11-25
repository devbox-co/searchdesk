require "test_helper"

class MapsSummaryTest < ActionDispatch::IntegrationTest
  setup do
    workspace = Workspace.create!(name: "Summary fixture")
    @site = workspace.sites.create!(name: "North", host: "north.example", location: "York")
    user = User.create!(email: "maps-viewer@example.test", password: "fixture-password-for-maps")
    workspace.memberships.create!(user: user, role: "viewer")
    post login_path, params: { session: { email: user.email, password: "fixture-password-for-maps" } }
  end

  def scan(site, id, day, term, metrics)
    site.source_snapshots.create!(provider: "Local Falcon", external_id: id, observed_on: day, title: "Scan", keyword: term,
      scope: "Google Maps scan for the selected site", metrics: metrics, source_url: "https://app.localfalcon.com/reports/view/#{id}")
  end

  test "latest Maps scan per keyword shows source-provided coverage and explicitly matched counts" do
    from = Date.new(2026, 4, 1)
    previous = scan(@site, "0123456789abcde", from, "plumber", {grid_size: 7, solv: 20})
    newer = scan(@site, "0123456789abcdf", from + 1, "plumber", {grid_size: 7, radius_miles: 5, grid_pins: 49, top_three_pins: 20,
      share_of_local_voice_pct: 40.82, compared_with_previous: {earlier_date: from.iso8601, matched_pins: 49, gained_top_three: 3, lost_top_three: 1}})
    live = scan(@site, "0123456789abcd0", from + 3, "tap repair", {grid_size: 7, radius: 5, distance_unit: "km", found_in: 49, solv: 0})
    @site.source_snapshots.create!(provider: "Local Falcon", external_id: "campaign-fixture", title: "Scheduled campaign", observed_on: from + 4,
      scope: "Google Maps", keyword: "campaign-only", metrics: {grid_size: 7})
    scan(@site, "0123456789abcd1", from, "apple-only", {grid_size: 7, platform: "apple", solv: 100})
    other = Workspace.create!(name: "Other tenant").sites.create!(name: "South", host: "south.example", location: "Bath")
    scan(other, "0123456789abcd2", from, "foreign-term", {grid_size: 9, solv: 90})
    get dashboard_path
    assert_select "a[href=?]", local_falcon_connection_path(anchor: "maps-scans"), text: "View Google Maps coverage"
    get local_falcon_connection_path
    assert_response :success
    assert_select "section[aria-labelledby=maps-scans] article", count: 2
    assert_select "a[href=?]", source_snapshot_path(previous), count: 0
    assert_select "a[href=?]", source_snapshot_path(newer)
    assert_select "a[href=?]", newer.source_url
    assert_select "section article", text: /plumber.*02 Apr 2026.*7 × 7 grid.*5 mi radius.*40.82% SoLV.*20 of 49 scanned locations.*01 Apr 2026 at 49 matched locations, 3 entered the top three and 1 left/m
    assert_select "section article", text: /tap repair.*5 km radius.*0% SoLV/m do |cards|
      assert_no_match(/Top three at|matched locations/, cards.first.text)
    end
    assert_select "a[href=?]", source_snapshot_path(live)
    assert_no_match(/foreign-term|apple-only|campaign-only/, response.body)
  end

  test "overview switches saved maps and preserves accessible readings when the street image is unavailable" do
    day = Date.current - 1
    selected = scan(@site, "0123456789abcde", day, "local repair", {grid_size: 3, solv: 50})
    selected.update!(map_grid: {"report_key"=>selected.external_id, "keyword"=>"local repair", "date"=>day.iso8601,
      "grid_size"=>3, "radius"=>2, "unit"=>"mi", "place_id"=>"verified-fixture", "street_map"=>true, "points"=>[
      {"lat"=>52.1, "lng"=>-1.0, "rank"=>1}, {"lat"=>52.0, "lng"=>-1.1, "rank"=>"20+"}]})
    summary_only = scan(@site, "0123456789abcdf", day + 1, "summary only", {grid_size: 5, found_in: 0, solv: 0})
    get dashboard_path, params: {map_scan: selected.external_id}
    assert_response :success
    assert_select "#maps-visibility input#lf-street[checked]"
    assert_select "#maps-visibility img[referrerpolicy=no-referrer][src=?]", street_map_path(selected)
    assert_select "#maps-visibility .lf-street a[href=?]", street_map_path(selected), text: "Open full-size street map"
    assert_select "#maps-visibility .lf-pin", count: 2
    assert_select "#maps-visibility summary", text: "Ranks at all 2 locations"
    assert_select "#maps-visibility tbody td", text: "20+"
    assert_select "#maps-visibility .lf-metric", text: /1 of 2/
    get dashboard_path, params: {map_scan: summary_only.external_id}
    assert_response :success
    assert_select "#maps-visibility img", count: 0
    assert_select "#maps-visibility .lf-pin", count: 0
    assert_select "#maps-visibility", text: /Scan summary available/
    assert_select "#maps-visibility .lf-metric strong", text: "0%"
  end

  test "sites without scans see an honest empty state" do
    get local_falcon_connection_path
    assert_response :success
    assert_select "section p", text: /No completed Google Maps scans/
    assert_select "section article", count: 0
  end
end
