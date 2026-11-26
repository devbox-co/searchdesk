require "test_helper"

class IntegrationEvidenceTest < ActionDispatch::IntegrationTest
  PLACE = "VerifiedPlace1234"

  setup do
    workspace = Workspace.create!(name: "Services")
    @site = workspace.sites.create!(name: "Shop", host: "integration.example", location: "York")
    @other = Workspace.create!(name: "Elsewhere").sites.create!(name: "Other", host: "other.example", location: "Leeds")
    user = User.create!(email: "service-manager@example.test", password: "local-password-for-tests")
    workspace.memberships.create!(user: user, role: "manager")
    post login_path, params: { session: { email: user.email, password: "local-password-for-tests" } }
  end

  test "Google cards show imported reports without claiming OAuth access and Semrush separates its API state" do
    day = Date.new(2026, 11, 21)
    record(@site, "gsc", "g1", day)
    record(@site, "gsc", "g2", day - 2)
    record(@site, "gsc", "daily-position-abc", day + 1, { "source_basis" => "final_api", "property" => "sc-domain:integration.example" })
    record(@site, "ga4", "a1", day)
    record(@site, "semrush", "s1", day)
    record(@other, "gsc", "g3", day + 2)
    record(@other, "semrush", "s2", day + 2)
    get integrations_path
    assert_select "[role=status]", text: /Local organic ranks.*Connected reporting sources/m
    %w[google-search-console google-analytics semrush].zip(%w[gsc ga4 semrush], [2, 1, 1]).each do |id, provider, count|
      get integrations_path, params: { q: id }
      assert_select ".badge", text: id == "semrush" ? "Imported reports" : "Not connected"
      filter = source_snapshots_path(provider: provider, origin: "imported")
      assert_select "a[href=?]", filter, text: /#{count} imported report/
      assert_select "small", text: "Latest record dated 21 Nov 2026"
      get integration_path(id)
      assert_select "a[href=?]", filter
      assert_select "p", text: /Automatic API sync unavailable/ if id == "semrush"
      get filter
      assert_response :success
      assert_select "article", count: count
    end
    @site.create_analytics_connection!(status: "connected", grant_key: SecureRandom.uuid)
    get integrations_path, params: {q: "google-analytics"}
    assert_select ".badge", text: "Not connected"
  end

  test "GBP needs a valid recent matching Local Falcon receipt and scoped period even if imported archive data exists" do
    first = Date.current - 31
    last = first + 27
    facts = { "place_id" => PLACE, "start" => first.iso8601, "end" => last.iso8601, "totals" => {} }
    record(@site, "Google Business Profile", "historic-gbp", last, facts)
    record(@other, "Google Business Profile", SourceSnapshot::GBP_CACHE_ID, last, facts)
    connector = @site.create_local_falcon_connection!(place_id: PLACE, verified_name: "Shop", refresh_token: "offline-only",
      status: "connected", synced_at: Time.current, result: {"gbp" => "Business Profile metrics through #{last}"})
    get integration_path("google-business-profile")
    assert_select "dd", text: "Provider portal"
    assert_select "a[href=?]", "https://business.google.com/"
    snapshot = record(@site, "Google Business Profile", SourceSnapshot::GBP_CACHE_ID, last, facts)
    get integrations_path, params: {q: "google-business-profile"}
    assert_select ".badge", text: "Connected via Local Falcon"
    assert_select "small", text: /#{first.strftime('%d %b %Y')} to #{last.strftime('%d %b %Y')}/
    get integration_path("google-business-profile")
    assert_select "a[href=?]", source_snapshot_path(snapshot)
    connector.update!(result: {"gbp" => "Business Profile metrics unavailable from this grant"})
    get integration_path("google-business-profile")
    assert_select "dd", text: "Provider portal"
    connector.update!(result: {"gbp" => "Business Profile metrics through #{last}"})
    snapshot.update!(metrics: facts.merge("place_id" => "AnotherPlace12345"))
    get integration_path("google-business-profile")
    assert_select "dd", text: "Provider portal"
    snapshot.update!(metrics: facts)
    connector.update!(status: "reconnect")
    get integration_path("google-business-profile")
    assert_select "dd", text: "Provider portal"
    connector.update!(status: "connected")
    snapshot.update_column(:updated_at, 30.days.ago)
    get integration_path("google-business-profile")
    assert_select "dd", text: "Provider portal"
  end

  private

  def record(site, provider, id, day, metrics = {})
    site.source_snapshots.create!(provider: provider, external_id: id, title: "#{provider} report", observed_on: day,
      scope: "Synthetic integration check", metrics: metrics)
  end
end
