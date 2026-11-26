require "test_helper"

class IntegrationCoverageTest < ActionDispatch::IntegrationTest
  setup do
    workspace = Workspace.create!(name: "Coverage fixtures")
    @site = workspace.sites.create!(name: "Town shop", host: "coverage.example", location: "York", rank_country_code: "GB")
    @other = Workspace.create!(name: "Private workspace").sites.create!(name: "Other", host: "elsewhere.example", location: "Leeds")
    @viewer = User.create!(email: "guide@example.test", password: "synthetic-example-password")
    workspace.memberships.create!(user: @viewer, role: "viewer")
  end

  test "public guide explains source choices without exposing a site's reports" do
    get public_catalogue_path
    assert_response :success
    assert_select ".integration-choice", text: /DataForSEO alone.*Semrush.*Maps grids.*free Google reports/m
    assert_select "[data-coverage]", count: 0
    assert_select "article h2", count: 17
  end

  test "manual site distinguishes untracked Semrush evidence, purchased checks, a report link and linked listing data" do
    login
    @site.site_report_links.create!(provider: "local-falcon", url: "https://app.localfalcon.com/reports/view/abcd")
    snapshot(@site, "semrush", "s1")
    snapshot(@other, "gsc", "private-gsc")
    get integrations_path
    assert_response :success
    assert_select "[data-coverage]", count: 5
    assert_select ".integration-choice", text: /bring your own local readings.*DataForSEO alone.*Import Semrush/m
    assert_select "[data-coverage=local]", text: /No matching campaign imported.*Manual import.*no complete reading/m
    assert_select "[data-coverage=maps]", text: /Link saved.*External report only/m
    assert_select "#services .badge-saved", text: "Link saved"
    assert_select "#services .badge-saved svg[aria-hidden=true]"
    assert_select "#services .badge-neutral", text: "Not connected"
    assert_select ".integration-hero a[href=?]", source_snapshots_path, text: "Browse source evidence"
    assert_select "[data-coverage=profile]", text: /Provider portal/
    assert_select "[data-coverage=google-search-console] a", text: "Read saved reports", count: 0
    assert_select ".integration-planned:not([open]) article", count: 8
    assert_select "#services form", count: 1
    assert_no_enqueued_jobs do
      get integrations_path, params: {q: "geogrid"}
      assert_select ".integration-service .service-name", text: "Local Falcon"
      assert_select "[data-coverage]", count: 0
    end
    get integrations_path, params: {q: "SerpAPI"}
    assert_select ".integration-planned[open] .service-name", text: "SerpAPI"
  end

  test "verified campaign, true organic readings and Google connection phases remain independent" do
    login
    phrase = "local plumber"
    keyword = Tracking::Enrollment.call(site: @site, phrase: phrase, devices: ["mobile"])
    day = Time.current.in_time_zone(@site.time_zone).to_date
    snapshot(@site, "semrush", "campaign", keyword: phrase, source_url: "https://www.semrush.com/tracking/overview/19_23.html?domain_1=coverage.example",
      observed_on: day, metrics: {series_method: Semrush::CampaignDashboard::METHOD, campaign_id: "19_23", domain: @site.host,
        location: "York", language: "en", engine: "google", device: "desktop", latest_date: day, latest_position: 3})
    Tracking::RecordResult.call(series: keyword.tracking_series.sole, captured_at: Time.current,
      items: [{"type" => "organic", "rank_group" => 1, "url" => "https://coverage.example/plumbing"}])
    snapshot(@site, "ga4", "traffic")
    @site.create_analytics_connection!(status: "choose_property", refresh_token: "offline-fixture", grant_key: SecureRandom.uuid)
    @site.create_search_console_connection!(status: "connected", property: "sc-domain:coverage.example", refresh_token: "offline-fixture")
    get integrations_path
    assert_select ".integration-choice", text: /Start with your imported Semrush campaign for York on desktop/m
    assert_select "[data-coverage=local] a", text: "View campaign positions"
    assert_select "[data-coverage=local]", text: /Manual import.*latest reading/m
    assert_select "[data-coverage=google-analytics]", text: /Choose property.*1 imported report/m
    assert_select "[data-coverage=google-analytics] a[href=?]", source_snapshots_path(provider: "ga4", origin: "imported")
    assert_select "[data-coverage=google-search-console]", text: /first report pending/
    @site.search_console_connection.update!(synced_at: 4.days.ago)
    get integrations_path
    assert_select "[data-coverage=google-search-console]", text: /Refresh overdue/
  end

  test "a selected Google property and a working grant give the owner a manage link and viewers a read link" do
    login
    membership = @viewer.memberships.find_by!(workspace: @site.workspace)
    membership.update!(role: "owner")
    get integration_path("google-search-console")
    assert_select "a[href=?]", search_console_path, text: "Set up Search Console"
    connection = @site.create_search_console_connection!(status: "connected", property: "sc-domain:coverage.example",
      refresh_token: "offline-fixture", synced_at: Time.current)
    get integration_path("google-search-console")
    assert_select "a[href=?]", search_console_path, text: "Manage Search Console"
    connection.update!(status: "reconnect")
    get integration_path("google-search-console")
    assert_select "a[href=?]", search_console_path, text: "Reconnect Search Console"
    membership.update!(role: "viewer")
    get integration_path("google-search-console")
    assert_select "a[href=?]", search_console_path, text: "View Search Console"
  end

  test "a working managed account and an existing Maps connection remain distinct from verified grid and Business Profile reports" do
    login
    @site.update!(tracking_mode: "dataforseo", rank_location_code: 123, rank_location_verified_at: Time.current, rank_location_name: @site.location)
    connection = @site.create_local_falcon_connection!(status: "connected", refresh_token: "offline-fixture",
      place_id: "fixture_place_123", verified_name: "Town shop", synced_at: Time.current, result: {"scans" => 0})
    provider = Class.new(Tracking::DataForSeo) do
      class << self
        attr_accessor :daily_task_limit
        def enabled? = true
      end
    end
    provider.daily_task_limit = 10
    stub_const(Tracking, :DataForSeo, provider) do
      get integrations_path
      assert_select ".integration-choice", text: /Add a keyword and device.*existing Local Falcon/m
      assert_select "[data-coverage=local]", text: /no complete reading yet/
      assert_select "[data-coverage=maps]", text: /Connected.*No saved grid/m
      assert_select "#services .badge-live", text: "Connected"
      assert_select "#services .badge-neutral", text: "No keywords enrolled"
      assert_select "[data-coverage=profile]", text: /Provider portal/
      keyword = Tracking::Enrollment.call(site: @site, phrase: "heating", devices: ["mobile"])
      series = keyword.tracking_series.sole
      get integrations_path
      assert_select "#services .badge-pending", text: "Configured · awaiting reading"
      series.update!(paused: true)
      get integrations_path
      assert_select ".integration-choice", text: /Resume a keyword's device/
      assert_select "#services .badge-neutral", text: "Tracking paused"
      series.update!(paused: false)
      Tracking::RecordResult.call(series: series, captured_at: Time.current,
        items: [{"type" => "organic", "rank_group" => 1, "url" => "https://coverage.example/heat"}])
      get integrations_path
      assert_select "#services .badge-live", text: "Reading received today"
      provider.daily_task_limit = 0
      get integrations_path
      assert_select "#services .badge-attention", text: "Daily allowance is zero"
      assert_select ".integration-choice", text: /disabled by the operator/
      assert_select "[data-coverage=local]", text: /latest reading/
      provider.daily_task_limit = 10
      connection.update!(synced_at: nil, verified_name: nil)
      get integrations_path
      assert_select "[data-coverage=maps]", text: /Verifying location/
      @site.update!(rank_location_verified_at: nil)
      get integrations_path
      assert_select "[data-coverage=local]", text: /Location verification needed/
      assert_select ".integration-choice", text: /Ask your administrator to verify the provider town/
    end
  end

  private

  def login
    post login_path, params: {session: {email: @viewer.email, password: "synthetic-example-password"}}
  end

  def snapshot(site, provider, external_id, **attrs)
    site.source_snapshots.create!({provider: provider, external_id: external_id, title: "Synthetic report",
      observed_on: Date.current, scope: "Coverage fixture", metrics: {}}.merge(attrs))
  end
end
