require "test_helper"
require "active_support/testing/constant_stubbing"

class AnalyticsConnectionTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::ConstantStubbing
  include ActiveJob::TestHelper

  setup do
    @keys = %w[GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET APP_HOST APP_PROTOCOL].to_h { |k| [k, ENV[k]] }
    ENV.update("GOOGLE_CLIENT_ID" => "fake-client", "GOOGLE_CLIENT_SECRET" => "fake-secret", "APP_HOST" => "localhost:3038", "APP_PROTOCOL" => "http")
    @user = User.create!(email: "analytics-test@example.org", password: "Test password with 28 chars!")
    @workspace = Workspace.create!(name: "Analytics team")
    @member = @workspace.memberships.create!(user: @user, role: "owner")
    @site = @workspace.sites.create!(name: "Shop", host: "example.test", location: "Somewhere", language: "en", time_zone: "UTC", tracking_mode: "manual")
    post login_path, params: { session: { email: @user.email, password: "Test password with 28 chars!" } }
  end

  teardown { @keys.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value } }

  def fixture_client(scope)
    Class.new(Analytics::Client) do
      define_method(:exchange) do |code:, verifier:|
        raise "Invalid exchange" unless code == "fixture-code" && verifier.present?
        { "access_token" => "fixture-access", "refresh_token" => "fixture-refresh", "scope" => scope, "expires_in" => 3600 }
      end
      def binding(token:, property:, host:)
        raise Analytics::Client::AccessError, "Choose a property with a matching web stream." unless token == "fixture-access" && host == "example.test" && property == "123"
        { property_id: property, property_name: "Example", property_zone: "Europe/London", verified_host: host, stream_ids: ["20"] }
      end
    end
  end

  def authorize_state
    post authorize_analytics_path
    assert_response :redirect
    params = Rack::Utils.parse_query(URI(response.location).query)
    assert_equal Analytics::Client::SCOPE, params["scope"]
    assert_equal "http://localhost:3038/analytics/callback", params["redirect_uri"]
    assert_equal "S256", params["code_challenge_method"]
    assert_equal Base64.urlsafe_encode64(Digest::SHA256.digest(AnalyticsGrant.sole.verifier), padding: false), params["code_challenge"]
    assert_not_includes response.location, "fake-secret"
    params.fetch("state")
  end

  test "analytics consent uses its own scope and encrypted grant and requires explicit verified property selection" do
    stub_const(Analytics, :Client, fixture_client(Analytics::Client::SCOPE)) do
      state = authorize_state
      get callback_analytics_path, params: { state: state, code: "fixture-code" }
      assert_redirected_to analytics_path
      c = @site.reload.analytics_connection
      assert_equal "choose_property", c.status
      assert_nil c.property_id
      assert_equal "fixture-refresh", c.refresh_token
      assert_not_equal "fixture-refresh", c.ciphertext_for(:refresh_token)
      assert_equal 0, AnalyticsGrant.count
      get callback_analytics_path, params: { state: state, code: "fixture-code" }
      assert_match(/expired/, flash[:alert])
      assert_no_enqueued_jobs { patch analytics_path, params: { property: "456" } }
      assert_nil c.reload.property_id
      assert_enqueued_with(job: AnalyticsSyncJob) { patch analytics_path, params: { property: "123" } }
      assert_equal "connected", c.reload.status
      get integration_path("google-analytics")
      assert_select "a[href=?]", analytics_path
      assert_match(/Connected/, response.body)
      assert_no_difference("SearchConsoleConnection.count") { delete analytics_path }
      assert_nil @site.reload.analytics_connection
    end
  end

  test "combined scopes are rejected and site switching cannot bind an earlier grant" do
    stub_const(Analytics, :Client, fixture_client([Analytics::Client::SCOPE, SearchConsole::Client::SCOPE].join(" "))) do
      get callback_analytics_path, params: { state: authorize_state, code: "fixture-code" }
      assert_nil @site.reload.analytics_connection
      assert_empty AnalyticsGrant.all
      state = authorize_state
      other = @workspace.sites.create!(name: "Other", host: "other.example", location: "Town", language: "en", time_zone: "UTC", tracking_mode: "manual")
      post select_site_path(other)
      get callback_analytics_path, params: { state: state, code: "fixture-code" }
      assert_nil other.reload.analytics_connection
      assert_nil @site.reload.analytics_connection
    end
  end

  test "viewers can see site-scoped reports and cannot grant, select, refresh, or disconnect" do
    @member.update!(role: "viewer")
    get analytics_path
    assert_response :success
    assert_select "h1", "Google Analytics 4"
    post authorize_analytics_path
    assert_response :forbidden
    get callback_analytics_path, params: { state: "anything" }
    assert_response :forbidden
    patch analytics_path, params: { property: "123" }
    assert_response :forbidden
    post sync_analytics_path
    assert_response :forbidden
    delete analytics_path
    assert_response :forbidden
  end
end
