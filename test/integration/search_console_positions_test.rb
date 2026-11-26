require "test_helper"

class SearchConsolePositionsTest < ActionDispatch::IntegrationTest
  class ClientFixture
    def sitemaps(token:, property:) = []

    attr_reader :calls
    def initialize
      @calls = []
    end

    def query(property:, token:, payload:)
      raise "unexpected scope" unless property == "sc-domain:example.test" && token == "fake" && payload[:dataState] == "final" && payload[:type] == "web"
      @calls << payload
      metrics = { "clicks" => 1, "impressions" => 4, "position" => 6.25, "ctr" => 0.25 }
      case payload[:dimensions]
      when ["date"] then [metrics.merge("keys" => ["2026-11-20"])]
      when ["date", "query"] then [metrics.merge("keys" => ["2026-11-20", "heating"])]
      when ["query", "page", "device"] then [metrics.merge("keys" => ["heating", "https://example.test/heat", "MOBILE"])]
      else [metrics]
      end
    end
  end

  setup do
    workspace = Workspace.create!(name: "Reporting")
    @site = workspace.sites.create!(name: "Business", host: "example.test", location: "New York", rank_country_code: "US")
    @user = User.create!(email: "positions@example.test", password: "safe-test-passphrase")
    workspace.memberships.create!(role: "owner", user: @user)
    post login_path, params: {session: {email: @user.email, password: "safe-test-passphrase"}}
    @term = Tracking::Enrollment.call(site: @site, phrase: "heating")
    @other = Tracking::Enrollment.call(site: @site, phrase: "repair")
  end

  test "archive defaults to the latest day of the correct national source and tracks independent baselines" do
    travel_to Time.utc(2026, 11, 24, 12) do
      archive(@term, [["2026-08-21", 0, nil], ["2026-08-22", 4, 18.5], ["2026-11-18", 2, 8.25]])
      archive(@other, [["2026-10-15", 2, 4.5], ["2026-11-18", 0, nil]])
      archive(@term, [["2026-07-01", 5, 1]], country: "GBR")
      view = SearchConsole::PositionDashboard.new(site: @site)
      assert_equal Date.new(2026, 11, 18), view.day
      main = view.rows.find { |r| r[:keyword] == @term }
      assert_equal Date.new(2026, 8, 22), main[:baseline][:date]
      assert_equal 10.25, main[:change]
      other = view.rows.find { |r| r[:keyword] == @other }
      assert_equal 4.5, other[:baseline][:position]
      assert_nil other[:change]
      assert_nil other[:current][:position]
      get rankings_path
      assert_select "nav[aria-label='Ranking source'] a[aria-current=page]", text: /Search Console · US average position/
      assert_select "tbody td", text: /No impressions/
      assert_select "tbody td", text: "Up 10.25"
      get rankings_path, params: { source: "gsc", day: "2026-11-19" }
      assert_select "tbody td", text: /Pending report/
      assert_select "tbody td strong", count: 0
      get rankings_path, params: { source: "gsc", day: "2026-11-13" }
      assert_select "tbody td", text: /No reported position/
      assert_select "tbody td strong", count: 0
      get rankings_path, params: { source: "local" }
      assert_select "nav[aria-label='Ranking source'] a[aria-current=page]", text: "Local organic rank"
      assert_select "tbody td strong", text: "No reading"
    end
  end

  test "Google final request preserves property totals and tracked pages, upserts the right national query data and survives repeats" do
    travel_to Time.utc(2026, 11, 24, 12) do
      connection = @site.create_search_console_connection!(property: "sc-domain:example.test", status: "connected", refresh_token: "offline",
        access_token: "fake", token_expires_at: 2.hours.from_now)
      archive(@term, [["2026-09-12", 5, 16.5], ["2026-11-18", 2, 10.0]])
      fake = ClientFixture.new
      assert SearchConsole::Synchronizer.call(connection, client: fake)
      request = fake.calls.find { |call| call[:dimensions] == %w[date query] }
      assert_equal "byProperty", request[:aggregationType]
      assert_includes request[:dimensionFilterGroups].first[:filters], {dimension: "country", operator: "equals", expression: "usa"}
      assert_equal "2026-11-20", connection.reload.report.dig("daily_scope", "through")
      assert_equal 1, connection.report.dig("current", "metrics", "clicks")
      assert_equal @term.phrase, connection.report.fetch("keyword_pages").sole["keyword"]
      assert_equal 0, RankObservation.count
      assert_no_difference "SourceSnapshot.count" do
        assert SearchConsole::Synchronizer.call(connection, client: fake)
      end
      v = SearchConsole::PositionDashboard.new(site: @site)
      first = v.rows.find { |row| row[:keyword] == @term }
      assert_equal 6.25, first[:current][:position]
      assert_equal 16.5, first[:baseline][:position]
      assert_equal 1, first[:current][:clicks]
      historical_day = SearchConsole::PositionDashboard.new(site: @site, requested_day: Date.new(2026,11,18))
      assert_nil historical_day.rows.find { |row| row[:keyword] == @term }[:current], "Final API omit must not become an old UI value"
      live = @site.source_snapshots.where("metrics->>'source_basis' = 'final_api'").first
      connection.update!(property: nil, status: "choose_property")
      get source_snapshot_path(live)
      assert_response :not_found
      connection.update!(property: "sc-domain:example.test", status: "connected")
      get source_snapshot_path(live)
      assert_response :success
      delete search_console_path
      assert_equal ["complete_ui_report"], @site.source_snapshots.pluck(:metrics).map { |m| m["source_basis"] }.uniq
    end
  end

  test "local rank remains default when it has an observation, and a different country cannot supply a baseline" do
    archive(@term, [["2026-10-15", 3, 9.5]])
    series = @term.tracking_series.find_by!(device: "mobile")
    inputs = series.settings.slice("keyword", "device", "host", "location", "language", "source", "depth")
    Tracking::ManualImport.call(series: series, payload: inputs.merge("captured_at" => Time.current.iso8601,
      "items" => [{"type" => "organic", "rank_group" => 1, "url" => "https://example.test/heating"}]))
    get rankings_path
    assert_select "nav[aria-label='Ranking source'] a[aria-current=page]", text: "Local organic rank"
    assert_select "#local-rank-desktop[aria-current=page]"
    patch market_search_console_path, params: {country: "gb"}
    assert_redirected_to search_console_path
    assert_equal "GBR", SearchConsole::DailyPositions.country_for(@site.reload)
    assert_not SearchConsole::PositionDashboard.new(site: @site).available?
    get rankings_path, params: {source: "gsc"}
    assert_select "h2", text: "Waiting for Search Console evidence"
  end

  private

  def archive(keyword, rows, country: "USA")
    month_end = rows.map(&:first).max
    @site.source_snapshots.create!(provider: "gsc", external_id: "archive-#{keyword.id}-#{country}", keyword: keyword.phrase,
      title: "Archive", observed_on: Date.new(2026,11,20), scope: "Exact query, national Web, all devices",
      metrics: {"series_method" => SearchConsole::DailyPositions::METHOD, "country" => country, "property" => "sc-domain:example.test",
        "search_type" => "web", "device_scope" => "all", "source_basis" => "complete_ui_report", "end" => month_end,
        "daily" => rows.map { |d, i, p| {"date" => d, "impressions" => i, "clicks" => 0, "average_position" => p} }})
  end
end
