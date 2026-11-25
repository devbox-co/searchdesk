require "test_helper"
require "active_support/testing/constant_stubbing"

class LocalFalconConnectionTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::ConstantStubbing

  class FixtureClient < LocalFalcon::Client
    PLACE = "ChIJexamplePlace000"
    KEY = "ab1234567890def"
    def register(_callback) = "public-client"
    def token(_id, _params) = { "access_token" => "test-access", "refresh_token" => "test-refresh", "expires_in" => 3600 }
    def revoke(*) = true
    def open_session(token) = self
    def read(tool, args)
      case tool
      when "listAllLocalFalconLocations"
        {"locations" => [{"place_id" => PLACE, "name" => "Local shop", "platform" => "google", "url" => "https://example.test/", "gbp_linked" => true}]}
      when "getLocalFalconReport"
        {"report_key" => KEY, "place_id" => PLACE, "platform" => "google"}
      when "listLocalFalconScanReports"
        row = {"report_key" => KEY, "keyword" => "shop", "platform" => "google", "place_id" => PLACE, "date" => Time.current.strftime("%m/%d/%Y 7:00 AM"),
          "grid_size" => "7", "radius" => "5", "measurement" => "mi", "arp" => "4.00", "atrp" => "4", "solv" => "44.90", "found_in" => "49",
          "data_points" => [{"secret" => "never retain me"}]}
        {"reports" => [row, row.merge("place_id" => "other")], "next_token" => false}
      when "listLocalFalconCampaignReports"
        row = {"report_key" => KEY, "name" => "Weekly", "locations" => "1", "keywords" => "1", "frequency" => "every week", "status" => "scheduled", "next_run" => Time.now.to_i.to_s}
        {"reports" => [row, row.merge("locations" => 2, "name" => "Other client")]}
      when "getLocalFalconGbpPerformanceMetrics"
        {"place_id" => PLACE, "start_date" => args[:startDate], "end_date" => args[:endDate], "totals" => args[:metrics].split(",").index_with { 4 }}
      else
        raise "Unexpected tool #{tool}"
      end
    end
  end

  setup do
    @owner = User.create!(email: "owner-maps@example.test", password: "private fixture pass")
    @workspace = Workspace.create!(name: "Local reporting")
    @membership = @workspace.memberships.create!(user: @owner, role: "owner")
    @site = @workspace.sites.create!(name: "Shop", host: "example.test", location: "Reading", time_zone: "UTC")
    @site.site_report_links.create!(provider: "local-falcon", url: "https://app.localfalcon.com/reports/view/#{FixtureClient::KEY}")
    post login_path, params: {session: {email: @owner.email, password: "private fixture pass"}}
  end

  test "owner uses saved report to connect once, scopes reads, syncs idempotently and disconnects" do
    stub_const(LocalFalcon, :Client, FixtureClient) do
      get local_falcon_connection_path
      assert_response :success
      post authorize_local_falcon_connection_path
      assert_response :see_other
      authorization = Rack::Utils.parse_query(URI(response.location).query)
      assert_equal "S256", authorization.fetch("code_challenge_method")
      state = authorization.fetch("state")
      perform_enqueued_jobs do
        get callback_local_falcon_connection_path, params: {state: state, code: "fixture"}
      end
      c = @site.reload.local_falcon_connection
      assert_equal "connected", c.status
      assert c.synced_at
      assert_equal FixtureClient::PLACE, c.place_id
      assert_equal "Local shop", c.verified_name
      assert_equal "test-refresh", c.refresh_token
      assert_no_match(/test-refresh/, c.refresh_token_before_type_cast)
      assert_nil c.verifier
      assert_equal 3, @site.source_snapshots.count
      assert_equal 1, c.result["scans"]
      assert_equal 1, c.result["campaigns"]
      assert_no_match(/data_points|Other client|secret/, @site.source_snapshots.to_json)
      get callback_local_falcon_connection_path, params: {state: state, code: "fixture"}
      assert_match(/expired/, flash[:alert])
      assert_no_difference("SourceSnapshot.count") { LocalFalconSyncJob.perform_now(c.id) }
      assert_no_enqueued_jobs { LocalFalconSyncJob.perform_now }
      delete local_falcon_connection_path
      assert_nil @site.reload.local_falcon_connection
      assert_equal 2, @site.source_snapshots.count
    end
  end

  test "pin refresh enriches an imported report without changing provenance or buying a scan" do
    captured = []
    client = Class.new(FixtureClient) do
      define_method(:read) do |tool, args|
        captured << [tool, args]
        next super(tool, args) unless tool == "getLocalFalconReport" && args[:fieldmask].include?("data_points")
        {"report_key" => FixtureClient::KEY, "keyword" => "shop", "platform" => "google", "place_id" => FixtureClient::PLACE,
         "date" => Time.current.strftime("%m/%d/%Y"), "grid_size" => 7, "radius" => 5, "measurement" => "mi",
         "data_points" => [{"lat" => "50.1", "lng" => "-1.2", "rank" => 1, "competitors" => ["secret"]}],
         "image" => "https://lf-static-v2.localfalcon.com/image/#{FixtureClient::KEY}"}
      end
    end
    saved = @site.source_snapshots.create!(provider: "Local Falcon", external_id: FixtureClient::KEY, observed_on: Date.current,
      title: "Original import", scope: "Historical Google Maps scan", keyword: "shop", source_path: "pilot/report.json",
      metrics: {grid_size: 7, top_three_pins: 12, grid_pins: 49})
    connection = @site.create_local_falcon_connection!(refresh_token: "fixture", access_token: "a",
      token_expires_at: 2.hours.from_now, status: "connected", place_id: FixtureClient::PLACE)
    stub_const(LocalFalcon, :Client, client) { 2.times { LocalFalconSyncJob.perform_now(connection.id) } }
    assert_equal "connected", connection.reload.status
    assert_equal 1, captured.count { |tool,args| tool == "getLocalFalconReport" && args[:fieldmask].include?("data_points") }
    assert_equal "Original import", saved.reload.title
    assert_equal({"grid_size"=>7, "top_three_pins"=>12, "grid_pins"=>49}, saved.metrics)
    assert_equal [{"lat"=>50.1, "lng"=>-1.2, "rank"=>1}], saved.map_grid.fetch("points")
    assert_equal "pilot/report.json", saved.source_path
    assert captured.all? { |tool, _| LocalFalcon::Client::READ_TOOLS.include?(tool) }
  end

  test "linked Business Profile cache expires and clinic-supplied archive remains separate" do
    c = @site.create_local_falcon_connection!(refresh_token: "fixture", access_token: "a", token_expires_at: 2.hours.from_now, status: "connected")
    stub_const(LocalFalcon, :Client, FixtureClient) { LocalFalconSyncJob.perform_now(c.id) }
    cache = @site.source_snapshots.linked_gbp_cache.sole
    cache.update_column(:updated_at, 30.days.ago)
    assert_not SourceSnapshot.visible_for(@site).exists?(cache.id)
    LocalFalconSyncJob.perform_now
    assert_not SourceSnapshot.exists?(cache.id)
    assert_equal 2, @site.source_snapshots.count
  end

  test "cross-site place is rejected before saving any report" do
    @site.update!(host: "other.test")
    c = @site.create_local_falcon_connection!(refresh_token: "fixture", access_token: "a", token_expires_at: 2.hours.from_now, status: "connected")
    stub_const(LocalFalcon, :Client, FixtureClient) { LocalFalconSyncJob.perform_now(c.id) }
    assert_equal "delayed", c.reload.status
    assert_match(/does not match/, c.last_error)
    assert_nil c.verified_name
    assert_empty @site.source_snapshots
  end

  test "all mutating routes require the owner and scope input cannot name a write tool" do
    @membership.update!(role: "manager")
    post authorize_local_falcon_connection_path
    assert_response :forbidden
    patch local_falcon_connection_path, params: {place_id: FixtureClient::PLACE}
    assert_response :forbidden
    post sync_local_falcon_connection_path
    assert_response :forbidden
    delete local_falcon_connection_path
    assert_response :forbidden
    assert_raises(LocalFalcon::Client::Error) { LocalFalcon::Client.new.read("runLocalFalconScan", {}) }
    assert_nil @site.reload.local_falcon_connection
  end
end
