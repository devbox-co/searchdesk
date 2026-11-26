require "test_helper"

class LocalFalconVisibilityMapTest < ActiveSupport::TestCase
  setup do
    @workspace = Workspace.create!(name: "Mapping")
    @site = @workspace.sites.create!(name: "Store", host: "map.example", location: "York")
    @day = Date.current
    @place = "ChIJfixtureBasingstoke"
    @key = "123456789abcdea"
    @row = { external_id: @key, observed_on: @day, keyword: "plumber", metrics: {grid_size: 3, radius: 2.5, distance_unit: "mi"} }
    @report = { "platform" => "google", "place_id" => @place, "report_key" => @key, "keyword" => "plumber",
      "date" => @day.strftime("%m/%d/%Y 4:15 PM"), "grid_size" => "3", "radius" => "2.5", "measurement" => "mi",
      "image" => "https://lf-static-v2.localfalcon.com/image/#{@key}", "places" => {"foreign" => "never persist"},
      "data_points" => [{ "lat" => "52.1", "lng" => "-1.1", "rank" => 2, "competitor_secret" => "ignore" },
        { "lat" => "52.2", "lng" => "-1.2", "rank" => "-" }, { "lat" => "52.1", "lng" => "-1.2", "rank" => "20+" }] }
  end

  def imported(key: @key, day: @day, site: @site)
    site.source_snapshots.create!(provider: "Local Falcon", external_id: key, title: "Scan", keyword: "plumber",
      scope: "Google Maps scan", observed_on: day, source_path: "import/verified.json",
      metrics: {grid_size: 3, radius_miles: 2.5, share_of_local_voice_pct: 33.33})
  end

  def attach(snapshot, place: @place, report: @report)
    row = @row.merge(external_id: snapshot.external_id, observed_on: snapshot.observed_on)
    detail = report.merge("report_key" => row[:external_id], "place_id" => place, "date" => row[:observed_on].strftime("%m/%d/%Y"))
    snapshot.update!(map_grid: LocalFalcon::ScanGrid.from_report(detail, row, place))
  end

  test "allowlisted provider coordinates and exact ranks appear in north-up order and are independent of import metrics" do
    snapshot = imported
    original = snapshot.metrics
    attach(snapshot)
    grid = LocalFalcon::ScanGrid.new(snapshot.reload)
    assert_equal original, snapshot.metrics
    assert_equal [nil, "20+", 2], grid.mapped_points.pluck("rank")
    assert_equal [7, 93, 93], grid.mapped_points.pluck("y")
    assert_equal [7, 7, 93], grid.mapped_points.pluck("x")
    refute_match(/foreign|competitor_secret/, snapshot.map_grid.to_json)
    assert_equal @report["image"], grid.street_map_url
    assert_nil LocalFalcon::VisibilityMap.new(site: @site, through: @day).counts
    assert_equal 33.33, LocalFalcon::VisibilityMap.new(site: @site, through: @day).scan.share
    snapshot.update!(map_grid: snapshot.map_grid.merge("keyword" => "another search"))
    assert_empty LocalFalcon::ScanGrid.new(snapshot).points
  end

  test "detail validates identity, scope, date, valid coordinates, unique points and trusted street image" do
    %w[report_key place_id platform keyword measurement date grid_size radius].each do |field|
      assert_nil LocalFalcon::ScanGrid.from_report(@report.merge(field => "wrong"), @row, @place), field
    end
    assert_nil LocalFalcon::ScanGrid.from_report(@report.merge("data_points" => Array.new(2, @report["data_points"].first)), @row, @place)
    assert_nil LocalFalcon::ScanGrid.from_report(@report.merge("data_points" => [{"lat" => 91, "lng" => 0}]), @row, @place)
    grid = LocalFalcon::ScanGrid.from_report(@report.merge("image" => "https://unrelated.example/image/#{@key}"), @row, @place)
    refute grid.fetch("street_map")
  end

  test "chart compares matched coordinates and verified business only, with site and date isolation" do
    selected = imported
    attach(selected)
    previous = imported(key: "123456789abcdeb", day: @day - 1)
    attach(previous)
    wrong_pins = imported(key: "123456789abcdec", day: @day - 2)
    points = @report["data_points"].map(&:dup)
    points.first["lat"] = "52.11"
    attach(wrong_pins, report: @report.merge("data_points" => points))
    wrong_place = imported(key: "123456789abcded", day: @day - 3)
    attach(wrong_place, place: "differentPlace")
    imported(key: "123456789abcdee", day: @day + 1)
    other = imported(key: "123456789abcdef", site: @workspace.sites.create!(name: "Other", host: "other.example", location: "Bath"))
    map = LocalFalcon::VisibilityMap.new(site: @site, through: @day, report_id: other.external_id)
    assert_equal selected.id, map.scan.snapshot.id
    assert_equal [previous.id, selected.id], map.history.map { |summary| summary.snapshot.id }
    assert_equal 4, map.options.size
    old = LocalFalcon::VisibilityMap.new(site: @site, through: @day, report_id: previous.external_id)
    assert_equal previous.id, old.scan.snapshot.id
    assert_equal [previous.id], old.history.map { |summary| summary.snapshot.id }
  end
end
