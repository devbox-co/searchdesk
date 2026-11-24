require "test_helper"

class SemrushCampaignPositionsTest < ActionDispatch::IntegrationTest
  setup do
    workspace = Workspace.create!(name: "Campaign fixtures")
    @site = workspace.sites.create!(name: "Shop", host: "shop.example", location: "York", rank_country_code: "GB")
    user = User.create!(email: "campaign-viewer@example.test", password: "fixture-session-passphrase")
    workspace.memberships.create!(user: user, role: "viewer")
    post login_path, params: {session: {email: user.email, password: "fixture-session-passphrase"}}
    @term = Tracking::Enrollment.call(site: @site, phrase: "plumber")
  end

  def campaign(term, first, last, site: @site, id: "123_456", host: "shop.example", market: "York, England, United Kingdom", device: "desktop", legacy: false, badge: nil, page: nil)
    first_date, first_rank = first
    last_date, last_rank = last
    short = market.delete_suffix(", United Kingdom")
    metrics = {previous_date: first_date, previous_position: first_rank, latest_date: last_date, latest_position: last_rank,
               latest_feature: badge, latest_reported_url: page}
    if legacy
      scope = "Semrush Position Tracking. #{short}, Google #{device} in English, #{host}. Local Pack and AI Overview positions are eligible."
    else
      scope = "Native Semrush Position Tracking, campaign #{id}. #{short}, Google #{device}, English, #{host}. The campaign includes eligible SERP features."
      metrics.merge!(campaign_id: id, domain: host, location: market, language: "en", engine: "google", device: device, series_method: Semrush::CampaignDashboard::METHOD)
    end
    site.source_snapshots.create!(provider: "semrush", keyword: term, external_id: SecureRandom.hex(10), title: "Position Tracking",
      observed_on: last_date, scope: scope, metrics: metrics,
      source_url: "https://www.semrush.com/tracking/overview/#{id}.html?domain_1=#{host}")
  end

  def gsc_date(day)
    @site.source_snapshots.create!(provider: "gsc", external_id: "archive-gsc-#{day}", keyword: @term.phrase, title: "Country averages", scope: "UK Web",
      observed_on: day, metrics: {series_method: SearchConsole::DailyPositions::METHOD, country: "GBR", property: "sc-domain:shop.example",
        search_type: "web", device_scope: "all", source_basis: "complete_ui_report", end: day, daily: [{date: day, impressions: 5, average_position: 7.5}]})
  end

  test "today uses the newest source and compares same-scope campaign evidence including features and absences" do
    travel_to Time.utc(2026,11,24,13) do
      gsc_date("2026-11-18")
      ["repair", "repairs near me", "thermostat"].each { |phrase| Tracking::Enrollment.call(site: @site, phrase: phrase) }
      old = campaign("plumber", ["2026-11-14",15], ["2026-11-20",9], legacy: true, badge: "AI Overview")
      latest = campaign("plumber", ["2026-11-20",9], ["2026-11-24",4], badge: "Local pack", page: "https://www.shop.example/plumbing")
      campaign("repair", ["2026-11-20",nil], ["2026-11-24",nil])
      campaign("repairs near me", ["2026-11-20",nil], ["2026-11-24",6])
      campaign("thermostat", ["2026-11-14",nil], ["2026-11-20",20])
      campaign("thermostat", ["2026-11-20",20], ["2026-11-24",5])
      campaign("untracked export", ["2026-11-20",2], ["2026-11-24",1])
      get rankings_path
      assert_response :success
      assert_select "nav a[aria-current=page]", text: "Semrush campaign"
      assert_select ".notice", text: /York, England, United Kingdom.*Google.*Desktop.*English.*shop.example/m
      assert_select "table th", text: /Today · 24 Nov 2026/
      assert_select "tbody tr", count: 4
      assert_select "tbody tr", text: /plumber.*#15.*14 Nov 2026.*#4.*24 Nov 2026.*Local pack.*Up 11/m
      assert_select "tbody tr", text: /No position reported.*No position reported/m
      assert_select "tbody tr", text: /repairs near me.*First reported position/m
      assert_select "tbody tr", text: /thermostat.*#20.*20 Nov 2026.*No position on 14 Nov 2026.*#5.*Up 15/m
      assert_no_match(/untracked export/, response.body)
      assert_select "a[href=?]", "https://www.shop.example/plumbing"
      [old, latest].each { |r| assert_select "a[href=?]", source_snapshot_path(r) }
      get rankings_path, params: {source: "campaign", day: "2026-11-20"}
      assert_select "tbody tr", text: /plumber.*#9.*AI Overview.*Up 6/m
      get rankings_path, params: {source: "campaign", day: "2026-11-14"}
      assert_select "tbody tr", text: /thermostat.*No position reported.*No position reported/m
      get rankings_path, params: {source: "campaign", day: "2026-11-22"}
      assert_select "tbody tr", text: /No observation on this date.*Last observation 20 Nov 2026 · #9/m
      get rankings_path, params: {source: "gsc"}
      assert_select "nav a[aria-current=page]", text: /Search Console/
      get rankings_path, params: {source: "local"}
      assert_select "nav a[aria-current=page]", text: "Local organic rank"
    end
    travel_to Time.utc(2026,11,26,13) do
      gsc_date("2026-11-25")
      get rankings_path
      assert_select "nav a[aria-current=page]", text: /Search Console/
    end
  end

  test "campaign, market, device, tenant and target host cannot supply each other's starting reading" do
    travel_to Time.utc(2026,11,24,13) do
      campaign("plumber", ["2026-11-20",9], ["2026-11-24",4])
      campaign("plumber", ["2026-09-01",86], ["2026-11-20",10], id: "123_777")
      campaign("plumber", ["2026-08-01",70], ["2026-11-20",20], market: "Bath, England, United Kingdom")
      campaign("plumber", ["2026-08-01",60], ["2026-11-20",19], device: "mobile")
      campaign("foreign-domain", ["2026-08-01",1], ["2026-11-20",3], host: "other.example")
      other = Workspace.create!(name: "Other").sites.create!(name: "Other store", host: "shop.example", location: "York")
      campaign("foreign-tenant", ["2026-08-01",1], ["2026-11-20",2], site: other)
      get rankings_path, params: {source: "campaign"}
      assert_select "select[name=campaign] option", count: 4
      assert_select "tbody tr", count: 1
      assert_select "tbody tr", text: /plumber.*#9.*20 Nov 2026.*#4.*Up 5/m
      assert_no_match(/foreign-/, response.body)
      key = css_select("select[name=campaign] option").find { |option| option.text.include?("Bath") }["value"]
      get rankings_path, params: {source: "campaign", campaign: key}
      assert_select ".notice", text: /Bath, England/
      assert_select "tbody tr", text: /#70.*#20.*Up 50/m
      get rankings_path, params: {source: "campaign", campaign: "unknown"}
      assert_select "h2", text: "No matching campaign selected"
    end
  end
end
