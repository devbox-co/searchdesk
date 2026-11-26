require "test_helper"

class AnalyticsTest < ActiveSupport::TestCase
  class GoogleFixture < Analytics::Client
    attr_reader :requests
    attr_accessor :empty_rows, :stream_host, :omit_metric

    def initialize
      @requests = []
      @stream_host = "www.shop.example"
    end

    private

    def json_request(url, token: nil, json: nil, **)
      @requests << [URI(url), json]
      raise "missing bearer" if token.blank?
      case URI(url).path
      when "/v1beta/properties/123"
        { "name" => "properties/123", "displayName" => "Shop Analytics", "timeZone" => "America/Los_Angeles" }
      when "/v1beta/properties/123/dataStreams"
        unless Rack::Utils.parse_query(URI(url).query)["pageToken"]
          return { "dataStreams" => [stream("11", "another.example"), stream("12", @stream_host, "ANDROID_APP_DATA_STREAM")], "nextPageToken" => "second" }
        end
        { "dataStreams" => [stream("13", @stream_host)] }
      when "/v1beta/properties/123:runReport"
        headers = METRICS.map { |name| { "name" => name } }
        headers.pop if omit_metric
        { "metricHeaders" => headers, "rowCount" => empty_rows ? 0 : 1, "metadata" => { "subjectToThresholding" => true },
          "rows" => empty_rows ? [] : [{ "metricValues" => %w[12 8 2.5].map { |v| { "value" => v } } }] }
      else
        raise "Unexpected request"
      end
    end

    def stream(id, host, type = "WEB_DATA_STREAM")
      { "name" => "properties/123/dataStreams/#{id}", "type" => type, "webStreamData" => { "defaultUri" => "https://#{host}" } }
    end
  end

  test "reports use verified streams, two exact property-local periods and Google organic traffic only" do
    workspace = Workspace.create!(name: "Sample workspace")
    site = workspace.sites.create!(name: "Shop", host: "shop.example", language: "en", location: "Town", time_zone: "UTC", tracking_mode: "manual")
    client = GoogleFixture.new
    travel_to Time.utc(2026, 11, 24, 4, 0) do
      c = site.create_analytics_connection!(property_id: "123", status: "connected", grant_key: "version1",
        access_token: "fixture-access", refresh_token: "fixture-refresh", token_expires_at: 1.hour.from_now)
      assert Analytics::Synchronizer.call(c, client: client)
      assert_equal ["13"], c.reload.stream_ids
      assert_equal ["2026-10-24", "2026-11-20"], c.report.fetch("current").values_at("start", "end")
      assert_equal ["2026-09-26", "2026-10-23"], c.report.fetch("previous").values_at("start", "end")
      assert_equal({ "sessions" => 12, "engaged_sessions" => 8, "unverified_key_events" => 2.5 }, c.report.dig("current", "metrics"))
      assert_equal true, c.report.dig("current", "subject_to_thresholding")
      assert_equal 2, site.source_snapshots.count
      assert_no_difference "SourceSnapshot.count" do
        assert Analytics::Synchronizer.call(c, client: client)
        assert_not Analytics::Synchronizer.call(c, client: client, scheduled: true)
      end
      reports = client.requests.select { |uri, _| uri.host == "analyticsdata.googleapis.com" }
      assert_equal 4, reports.size
      reports.each do |_, request|
        assert_nil request[:dimensions]
        assert_equal %w[sessions engagedSessions keyEvents], request[:metrics].pluck(:name)
        filters = request.dig(:dimensionFilter, :andGroup, :expressions).map { |e| e.fetch(:filter) }
        assert_equal({ "streamId" => ["13"], "hostName" => ["shop.example", "www.shop.example"], "sessionSource" => ["google"], "sessionMedium" => ["organic"] },
                     filters.to_h { |f| [f[:fieldName], f.dig(:inListFilter,:values)] })
      end
      client.stream_host = "another.example"
      assert_not Analytics::Synchronizer.call(c, client: client)
      assert_equal "reconnect", c.reload.status
      assert_equal 2, site.source_snapshots.count
      assert_equal 4, client.requests.count { |uri, _| uri.host == "analyticsdata.googleapis.com" }
    end
  end

  test "an empty provider result preserves missing data and unexpected headers fail closed" do
    client = GoogleFixture.new
    binding = client.binding(token: "fixture", property: "properties/123", host: "shop.example")
    client.empty_rows = true
    options = { token: "fixture", binding: binding, from: Date.new(2026, 5, 1), through: Date.new(2026, 5, 28) }
    assert_nil client.period(**options).fetch("metrics")
    client.omit_metric = true
    assert_raises(Analytics::Client::Error) { client.period(**options) }
    assert_raises(Analytics::Client::Error) { client.binding(token: "fixture", property: "123/path", host: "shop.example") }
  end
end
