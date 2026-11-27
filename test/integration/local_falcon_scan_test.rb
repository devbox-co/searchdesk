require "test_helper"
require "active_support/testing/constant_stubbing"

class LocalFalconScanTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::ConstantStubbing

  PLACE = "ChIJscanfixture123"
  KEY = "abc0123456789de"
  TERM = "heating repairs"

  test "M1 submits once with owner approval, polls, saves a verified grid, and exports it" do
    owner = User.create!(email: "maps-owner@example.test", password: "long-maps-test-password")
    workspace = Workspace.create!(name: "Maps workflow")
    membership = workspace.memberships.create!(user: owner, role: "owner")
    site = workspace.sites.create!(name: "Fixture heating", host: "heating.example", location: "Bath")
    term = site.keywords.create!(phrase: TERM)
    site.create_local_falcon_connection!(status: "connected", place_id: PLACE, verified_name: site.name,
      access_token: "fixture", refresh_token: "fixture", token_expires_at: 2.hours.from_now,
      ai_grant_revision: "scan-fixture", synced_at: Time.current)
    post login_path, params: { session: { email: owner.email, password: "long-maps-test-password" } }
    location = { "place_id" => PLACE, "platform" => "google", "url" => "https://heating.example/", "lat" => "51.5", "lng" => "-0.5" }
    result = { "report_key" => KEY, "place_id" => PLACE, "keyword" => TERM, "date" => Date.current.strftime("%m/%d/%Y"),
      "grid_size" => "3", "radius" => "2.5", "measurement" => "mi", "platform" => "google",
      "lat" => "51.5", "lng" => "-0.5", "arp" => "2.0", "solv" => "88.89",
      "data_points" => 9.times.map { |index| { "lat" => 51.5 + index * 0.01, "lng" => -0.5, "rank" => index == 8 ? "20+" : "2" } } }
    submissions = []
    reads = 0
    fake = Class.new(LocalFalcon::Client) do
      define_method(:open_session) { |*| self }
      define_method(:call_rpc) do |_method, input|
        case input.fetch(:name)
        when "listAllLocalFalconLocations"
          data = { "locations" => [location] }
        when "runLocalFalconScan"
          submissions << input.fetch(:arguments)
          data = { "success" => true, "report_key" => KEY, "status" => "pending" }
        when "getLocalFalconReport"
          reads += 1
          data = reads == 1 ? { "_mcp_status" => "processing" } : result
        else
          raise "Unexpected provider operation"
        end
        [{ "structuredContent" => data }, {}]
      end
    end

    route = request_maps_scan_seo_workflows_path
    approval = { keyword_id: term.id, size: "3", radius: "2.5", revision: LocalFalcon::ScanCollection.revision(site) }
    get setup_seo_workflows_path
    assert_select "#M1 form[action=?]", route
    post route, params: approval
    assert_empty LocalFalcon::ScanCollection.scope(site)
    stub_const(LocalFalcon, :Client, fake) do
      post route, params: approval.merge(approved: "1")
      receipt = LocalFalcon::ScanCollection.scope(site).sole
      assert_redirected_to source_snapshot_path(receipt)
      post route, params: approval.merge(approved: "1")
      assert_redirected_to source_snapshot_path(receipt)
      LocalFalconScanJob.perform_now(receipt.id, owner.id)
      assert_equal "pending", receipt.reload.metrics.fetch("status")
      LocalFalconScanJob.perform_now(receipt.id, owner.id)
      assert_equal "pending", receipt.reload.metrics.fetch("status")
      LocalFalconScanJob.perform_now(receipt.id, owner.id)
      assert_equal "captured", receipt.reload.metrics.fetch("status")
      LocalFalconScanJob.perform_now(receipt.id, owner.id)
      assert_equal [{ placeId: PLACE, keyword: TERM, gridSize: "3", radius: 2.5, measurement: "mi",
        lat: 51.5, lng: -0.5, platform: "google", aiAnalysis: false }], submissions
      snapshot = site.source_snapshots.find(receipt.metrics.fetch("snapshot_id"))
      assert_equal 9, LocalFalcon::ScanGrid.new(snapshot).points.size
      get evidence_preview_seo_workflows_path(template: "M1")
      assert_select "a[href=?]", source_snapshot_path(snapshot)
      get geogrid_source_snapshot_path(snapshot)
      assert_equal "text/csv", response.media_type
      assert_equal 10, CSV.parse(response.body).size
      assert_includes response.body, "21,20+"
      get export_evidence_seo_workflows_path
      grid = JSON.parse(response.body).fetch("maps_grids").sole
      assert_equal [TERM, KEY, 9], [grid["keyword"], grid["reference"], grid.fetch("points").size]

      result["place_id"] = "ChIJotherfixture"
      post import_maps_grid_seo_workflows_path, params: { report_key: KEY }
      assert_redirected_to setup_seo_workflows_path(anchor: "M1")
      assert_match(/does not match/, flash[:alert])
      membership.update!(role: "viewer")
      post route, params: approval.merge(approved: "1")
      assert_response :forbidden
      get geogrid_source_snapshot_path(snapshot)
      assert_response :forbidden
    end
  end
end
