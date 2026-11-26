require "test_helper"
require "active_support/testing/constant_stubbing"
require "net/http"
require "zlib"

class StreetMapsTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::ConstantStubbing

  setup do
    workspace = Workspace.create!(name: "Maps")
    @site = workspace.sites.create!(name: "Selected site", host: "north.example", location: "York")
    user = User.create!(email: "maps@example.test", password: "fixture-password-for-maps")
    workspace.memberships.create!(user: user, role: "viewer")
    post login_path, params: { session: { email: user.email, password: "fixture-password-for-maps" } }
    @scan = saved_scan(@site)
    @calls = []
  end

  def saved_scan(site)
    key = "0123456789abcdf"
    day = 90.days.ago.to_date
    site.source_snapshots.create!(provider: "Local Falcon", external_id: key, observed_on: day, title: "Scan", keyword: "local repair",
      scope: "Google Maps", metrics: {grid_size: 1, place_id: "fixture-place"},
      map_grid: {report_key: key, keyword: "local repair", date: day.iso8601, grid_size: 1, place_id: "fixture-place",
        street_map: true, points: [{lat: 52.0, lng: -1.0, rank: 2}]})
  end

  def png
    chunk = ->(type, data) { [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N") }
    "\x89PNG\r\n\x1a\n".b + chunk.call("IHDR", [1, 1, 8, 2, 0, 0, 0].pack("N2C5")) +
      chunk.call("IDAT", Zlib.deflate("\0\x22\x66\x88".b)) + chunk.call("IEND", "".b)
  end

  def with_provider(code: "200", type: "image/png", bytes: png)
    calls = @calls
    transport = Class.new(Net::HTTP) do
      define_method(:request) do |request, &receive|
        calls << [address, port, use_ssl?, request.path, request["Authorization"]]
        response = Net::HTTPResponse.new("1.1", code, "fixture")
        response["Content-Type"] = type
        response["Location"] = "https://untrusted.example/redirect" if code == "302"
        response.define_singleton_method(:read_body) { |&read| read.call(bytes) }
        receive.call(response)
      end
    end
    stub_const(Net, :HTTP, transport) { yield }
  end

  test "a viewer can open an older saved map and subsequent requests use the private durable copy" do
    with_provider do
      2.times do
        get street_map_path(@scan)
        assert_response :success
        assert_equal "image/png", response.media_type
        assert_equal png, response.body.b
        assert_includes response.headers["Cache-Control"], "no-store"
      end
    end
    assert_equal [["lf-static-v2.localfalcon.com", 443, true, "/image/#{@scan.external_id}", nil]], @calls
    assert_equal png, LocalFalconStreetMap.find_by!(source_snapshot: @scan).png
  end

  test "rejects malformed images and redirects, then retries a temporary failure" do
    corrupt = png.dup
    corrupt.setbyte(35, corrupt.getbyte(35) ^ 1)
    with_provider(bytes: corrupt) do
      2.times do
        get street_map_path(@scan)
        assert_response :service_unavailable
        assert_equal "30", response.headers["Retry-After"]
      end
    end
    assert_equal 1, @calls.size
    travel 31.seconds do
      with_provider(code: "302") { get street_map_path(@scan) }
      assert_response :service_unavailable
      assert_equal 2, @calls.size
      assert_nil LocalFalconStreetMap.find_by!(source_snapshot: @scan).png
    end
    travel 62.seconds do
      with_provider { get street_map_path(@scan) }
      assert_response :success
      assert_equal png, response.body.b
    end
  end

  test "authentication, site selection and grid binding apply even when a PNG is already saved" do
    with_provider do
      get street_map_path(@scan)
      assert_response :success
      signed_out = open_session
      signed_out.get street_map_path(@scan)
      assert_equal login_url, signed_out.response.location

      other = @site.workspace.sites.create!(name: "Other site", host: "south.example", location: "Bath")
      get street_map_path(saved_scan(other))
      assert_response :not_found
      @scan.update!(map_grid: @scan.map_grid.merge("place_id" => "different-business"))
      get street_map_path(@scan)
      assert_response :not_found
    end
    assert_equal 1, @calls.size
  end
end
