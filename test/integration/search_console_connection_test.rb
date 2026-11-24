require "test_helper"
require "active_support/testing/constant_stubbing"

class SearchConsoleConnectionTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::ConstantStubbing
  def setup
    @password = "Test account password 794!"
    user = User.create!(email: "gsc@example.org", password: @password, password_confirmation: @password)
    @workspace = Workspace.create!(name: "Reporting team")
    @workspace.memberships.create!(user: user, role: "owner")
    @site = @workspace.sites.create!(name: "Shop", host: "example.test", location: "Somewhere", language: "en", time_zone: "UTC", tracking_mode: "manual")
    post login_path, params: { session: { email: user.email, password: @password } }
  end

  test "owner sees unconfigured form, fake callback does not bind data and wrong property is rejected" do
    get search_console_path
    assert_response :success
    assert_select "h1", "Google Search Console"
    get callback_search_console_path, params: { state: "unknown-state", code: "never-exchanged" }
    assert_redirected_to search_console_path
    assert_nil @site.reload.search_console_connection
    c = @site.create_search_console_connection!(status: "choose_property", refresh_token: "stored", allowed_properties: ["sc-domain:example.test"])
    patch search_console_path, params: { property: "sc-domain:outside.test" }
    assert_nil c.reload.property
    assert_enqueued_with(job: SearchConsoleSyncJob) do
      patch search_console_path, params: { property: "sc-domain:example.test" }
    end
    assert_equal "sc-domain:example.test", c.reload.property
    assert_difference "SearchConsoleConnection.count", -1 do
      delete search_console_path
    end
  end

  test "viewer may read connector status but cannot initiate or modify the grant" do
    @workspace.memberships.first.update!(role: "viewer")
    get search_console_path
    assert_response :success
    post authorize_search_console_path
    assert_response :forbidden
    assert_no_difference "SearchConsoleGrant.count" do
      get callback_search_console_path, params: { state: "irrelevant" }
      assert_response :forbidden
    end
    delete search_console_path
    assert_response :forbidden
  end

  test "successful callback consumes its claim and persists tokens only after screening the property list" do
    old = %w[GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET].to_h { |key| [key, ENV[key]] }
    ENV.update("GOOGLE_CLIENT_ID" => "demo-client", "GOOGLE_CLIENT_SECRET" => "demo-secret")
    fake = Class.new(SearchConsole::Client) do
      def exchange(code:, verifier:)
        raise "wrong exchange" unless code == "fixture-code" && verifier.present?
        { "access_token" => "fixture-access", "refresh_token" => "fixture-refresh", "scope" => SearchConsole::Client::SCOPE, "expires_in" => 3600 }
      end

      private

      def json_request(_url, **_options)
        { "siteEntry" => [
          { "siteUrl" => "sc-domain:outside.test", "permissionLevel" => "siteOwner" },
          { "siteUrl" => "http://example.test/", "permissionLevel" => "siteUnverifiedUser" },
          { "siteUrl" => "sc-domain:example.test", "permissionLevel" => "siteOwner" }
        ] }
      end
    end
    stub_const(SearchConsole, :Client, fake) do
      post authorize_search_console_path
      state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
      get callback_search_console_path, params: { state: state, code: "fixture-code" }
      assert_redirected_to search_console_path
      connection = @site.reload.search_console_connection
      assert_equal ["sc-domain:example.test"], connection.allowed_properties
      assert_nil connection.property
      assert_equal "choose_property", connection.status
      assert_equal "fixture-refresh", connection.refresh_token
      assert_equal 0, SearchConsoleGrant.count
      get callback_search_console_path, params: { state: state, code: "fixture-code" }
      assert_match(/expired/, flash[:alert])
    end
  ensure
    old&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  test "oauth request binds state and S256 verifier without transmitting the secret" do
    previous = %w[GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET APP_HOST APP_PROTOCOL].to_h { |key| [key, ENV[key]] }
    ENV.update("GOOGLE_CLIENT_ID" => "dummy-app", "GOOGLE_CLIENT_SECRET" => "dummy-secret", "APP_HOST" => "localhost:3038", "APP_PROTOCOL" => "http")
    post authorize_search_console_path
    assert_response :redirect
    uri = URI(response.location)
    assert_equal "accounts.google.com", uri.host
    q = Rack::Utils.parse_query(uri.query)
    flow = SearchConsoleGrant.sole
    assert_equal "S256", q["code_challenge_method"]
    assert_equal Base64.urlsafe_encode64(Digest::SHA256.digest(flow.verifier), padding: false), q["code_challenge"]
    assert_equal Digest::SHA256.hexdigest(q.fetch("state")), flow.state_digest
    assert_equal SearchConsole::Client::SCOPE, q["scope"]
    assert_equal "http://localhost:3038/search_console/callback", q["redirect_uri"]
    assert_not_includes response.location, "dummy-secret"
    get callback_search_console_path, params: { state: q["state"], error: "access_denied" }
    assert_not SearchConsoleGrant.exists?(flow.id)
    assert_nil @site.reload.search_console_connection
  ensure
    previous&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end
end
