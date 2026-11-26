require "test_helper"

class SearchConsoleTest < ActiveSupport::TestCase
  class FakeClient
    def sitemaps(token:, property:) = []

    attr_reader :requests

    def initialize
      @requests = []
    end

    def refresh(token)
      raise "unexpected refresh token" unless token == "private-refresh"
      { "access_token" => "fresh-access", "expires_in" => 3600 }
    end

    def query(token:, property:, payload:)
      raise "wrong scope" unless token == "fresh-access" && property == "sc-domain:sample.test" && payload[:dataState] == "final" && payload[:type] == "web"
      @requests << payload
      if payload[:dimensions] == ["date"]
        [{ "keys" => ["2026-11-20"], "clicks" => 1, "impressions" => 4, "ctr" => 0.25, "position" => 6.25 }]
      elsif payload[:dimensions]
        [metrics.merge("keys" => ["heating", "https://sample.test/heating", "MOBILE"]),
         metrics.merge("keys" => ["heating", "https://sample.test/contact?email=hidden", "DESKTOP"]),
         metrics.merge("keys" => ["heating", "https://unrelated.test/heating", "MOBILE"]),
         metrics.merge("keys" => ["heating", "https://other.sample.test/heating", "MOBILE"])]
      else
        [metrics]
      end
    end

    def metrics
      { "clicks" => 3, "impressions" => 24, "ctr" => 0.125, "position" => 4.75 }
    end
  end

  setup do
    @site = Workspace.create!(name: "A").sites.create!(name: "A site", host: "sample.test", location: "Sample town",
      tracking_mode: "manual", language: "en", time_zone: "UTC")
  end

  test "only matching verified root properties are eligible" do
    assert SearchConsole::Client.matches?("sc-domain:sample.test", @site.host)
    assert SearchConsole::Client.matches?("https://www.sample.test/", @site.host)
    %w[https://sample.test/blog/ https://sample.test:8080/ https://sample.test.evil.test/ sc-domain:evil.test https://anyone@sample.test/].each do |property|
      assert_not SearchConsole::Client.matches?(property, @site.host), property
    end
  end

  test "grant refresh, property totals and joint tracked detail with encrypted secrets" do
    travel_to Time.utc(2026, 11, 24, 12) do
      @site.keywords.create!(phrase: "heating")
      connection = @site.create_search_console_connection!(property: "sc-domain:sample.test", status: "connected", refresh_token: "private-refresh")
      fake = FakeClient.new
      assert SearchConsole::Synchronizer.call(connection, client: fake)
      c = connection.reload
      assert_equal "connected", c.status
      assert_equal "2026-11-20", c.data_through.iso8601
      assert_equal ["2026-10-24", "2026-11-20"], c.report.fetch("current").values_at("start", "end")
      assert_equal 3, c.report.dig("current", "metrics", "clicks")
      assert_equal [{"date" => "2026-11-20", "clicks" => 1, "impressions" => 4}], c.report.fetch("performance_days")
      assert_equal 1, c.report.fetch("keyword_pages").length
      refute_includes c.report.to_json, "unrelated.test"
      refute_includes c.report.to_json, "other.sample.test"
      assert_equal true, c.report["partial_detail"]
      assert_equal "fresh-access", c.access_token
      assert_not_includes c.ciphertext_for(:refresh_token), "private-refresh"
      assert_equal 1, c.search_console_reports.count
      assert_equal 4, fake.requests.size
      assert_equal 0, RankObservation.count
      assert_no_difference "SearchConsoleReport.count" do
        assert SearchConsole::Synchronizer.call(c, client: FakeClient.new)
      end
    end
  end

  test "errors do not replace the previous report" do
    connection = @site.create_search_console_connection!(property: "sc-domain:sample.test", status: "connected",
      refresh_token: "private-refresh", report: { "old" => "result" })
    client = FakeClient.new
    def client.refresh(_token)
      raise SearchConsole::Client::AccessError, "Access revoked"
    end
    assert_not SearchConsole::Synchronizer.call(connection, client: client)
    assert_equal "reconnect", connection.reload.status
    assert_equal({ "old" => "result" }, connection.report)
  end

  test "scheduled reads catch up after sleep and collapse overdue duplicate deliveries" do
    travel_to Time.utc(2026, 11, 24, 13) do
      connection = @site.create_search_console_connection!(property: "sc-domain:sample.test", status: "connected",
        refresh_token: "private-refresh", synced_at: 2.days.ago)
      fake = FakeClient.new
      assert SearchConsole::Synchronizer.call(connection, client: fake, scheduled: true)
      reads = fake.requests.size
      assert_not SearchConsole::Synchronizer.call(connection, client: fake, scheduled: true)
      assert_equal reads, fake.requests.size
      connection.update!(synced_at: 2.days.ago, status: "delayed", sync_started_at: 20.minutes.ago)
      assert_not SearchConsoleConnection.due_for_sync.exists?(connection.id)
      connection.update!(sync_started_at: 2.hours.ago)
      assert SearchConsoleConnection.due_for_sync.exists?(connection.id)
    end
  end
end
