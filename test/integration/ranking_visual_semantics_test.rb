require "test_helper"

class RankingVisualSemanticsTest < ActionDispatch::IntegrationTest
  setup do
    workspace = Workspace.create!(name: "Reporting studio")
    @site = workspace.sites.create!(name: "Repair shop", host: "shop.example", location: "York", rank_country_code: "GB")
    owner = User.create!(email: "rank-layout@example.test", password: "visual-fixture-password")
    workspace.memberships.create!(user: owner, role: "owner")
    post login_path, params: {session: {email: owner.email, password: "visual-fixture-password"}}
  end

  test "campaign positions keep readable movement and search feature keys alongside symbolic table cells" do
    travel_to Time.utc(2026, 11, 24, 12) do
      add_reading("repairs", 9, 3, "Local pack")
      add_reading("heating", 1, 4, "AI Overview")
      add_reading("drains", 5, 5, nil)
      get rankings_path, params: {source: "campaign"}
      assert_response :success

      assert_select ".rank-source-tabs a[aria-label='Local organic rank'] .rank-source-detail", text: "organic"
      assert_select ".rank-source-tabs a[aria-label^='Search Console'] .rank-source-detail", text: /average position/
      assert_select ".rank-source-tabs a[aria-current='page'][aria-label='Semrush campaign'] .rank-source-detail", text: "campaign"
      assert_select ".rank-key[aria-label='Table key']" do
        assert_select ".rank-key-item", text: "Up"
        assert_select ".rank-key-item", text: "Down"
        assert_select ".rank-feature--map span:not(.rank-sr-only)", text: "Local pack"
        assert_select ".rank-feature--ai span:not(.rank-sr-only)", text: "AI Overview"
      end

      assert_select "table[role=table] tbody [role=row]", count: 3
      {"Local pack" => "map", "AI Overview" => "ai"}.each do |name, style|
        assert_select "td .rank-feature--#{style}.rank-feature--icon[title=?]", name, count: 1 do
          assert_select "svg[aria-hidden=true][focusable=false]"
          assert_select ".rank-sr-only", text: name
        end
      end
      {"Up" => "6", "Down" => "3"}.each do |direction, magnitude|
        assert_select "td .rank-change[title=?]", "#{direction} #{magnitude}" do
          assert_select "svg[aria-hidden=true]"
          assert_select ".rank-sr-only", text: direction
          assert_select "span:not(.rank-sr-only)", text: magnitude
        end
      end
      assert_select "td .rank-change--same", text: "No change"
      get rankings_path, params: {source: "campaign", day: "2026-11-23"}
      assert_select "td", text: /No observation on this date/, count: 3
      assert_select "td .rank-change[title='No comparison']", count: 3
      assert_select "td .rank-feature--icon", count: 0
    end
  end

  test "Search Console links the starting date and selected value to the exact reports for that query" do
    travel_to Time.utc(2026, 11, 24, 12) do
      keyword = Tracking::Enrollment.call(site: @site, phrase: "repairs")
      records = [["2026-11-17", 11.5], ["2026-11-20", 3.25]].map do |day, position|
        @site.source_snapshots.create!(
          provider: "gsc", external_id: "archive-#{day}", keyword: keyword.phrase, title: "Search Console reading",
          observed_on: day, scope: "UK Web, all devices",
          metrics: {series_method: SearchConsole::DailyPositions::METHOD, property: "sc-domain:shop.example",
            country: "GBR", search_type: "web", device_scope: "all", source_basis: "complete_ui_report", end: day,
            daily: [{date: day, impressions: 8, clicks: 0, average_position: position}]}
        )
      end
      get rankings_path, params: {source: "gsc", day: "2026-11-20"}
      assert_response :success
      assert_select "tbody td a[href=?]", source_snapshot_path(records.first), text: "17 Nov 2026"
      assert_select "tbody td strong a[href=?]", source_snapshot_path(records.last), text: "3.25"
      assert_select "tbody th a[href=?]", source_snapshots_path(provider: "gsc", keyword: keyword.phrase), text: keyword.phrase
    end
  end

  private

  def add_reading(phrase, first, latest, feature)
    Tracking::Enrollment.call(site: @site, phrase: phrase)
    @site.source_snapshots.create!(
      provider: "semrush", external_id: phrase, title: "Imported campaign", keyword: phrase,
      scope: "York, Google desktop in English", observed_on: "2026-11-24",
      source_url: "https://www.semrush.com/tracking/overview/123_456.html?domain_1=shop.example",
      metrics: {
        series_method: Semrush::CampaignDashboard::METHOD, campaign_id: "123_456",
        domain: "shop.example", location: "York, England, United Kingdom", device: "desktop", engine: "google", language: "en",
        previous_date: "2026-11-20", previous_position: first, latest_date: "2026-11-24", latest_position: latest, latest_feature: feature
      }
    )
  end
end
