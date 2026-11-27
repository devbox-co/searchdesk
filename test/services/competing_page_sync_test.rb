require "test_helper"
require "active_support/testing/constant_stubbing"

class CompetingPageSyncTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::ConstantStubbing
  include ActiveJob::TestHelper

  class Client
    attr_reader :requests, :refreshes
    attr_accessor :on_read, :unscoped, :quota_error

    def initialize
      @requests = []
      @refreshes = 0
    end

    def refresh(_grant)
      @refreshes += 1
      {"access_token" => "fixture-access", "expires_in" => 3600}
    end

    def query(token:, property:, payload:)
      raise "Unexpected property or token" unless token == "fixture-access" && property == "sc-domain:heating.test"
      requests << payload
      on_read&.call
      raise SearchConsole::Client::Error, "Google request could not complete (HTTP 429)." if quota_error
      includes = Regexp.new(payload[:dimensionFilterGroups].first[:filters].last.fetch(:expression)).match?("central heating")
      return [] unless includes
      if payload[:aggregationType] == "byProperty"
        [{"keys" => ["central heating", "DESKTOP"], "clicks" => 2, "impressions" => 12}]
      else
        rows = [{"keys" => ["central heating", "DESKTOP", "https://heating.test/boilers"], "clicks" => 2, "impressions" => 10, "position" => 1.5},
          {"keys" => ["central heating", "DESKTOP", "https://heating.test/guide"], "clicks" => 1, "impressions" => 8, "position" => 7.25}]
        rows << {"keys" => ["central heating", "MOBILE", "https://heating.test/contact?private=a"], "clicks" => 0, "impressions" => 1, "position" => 3} if unscoped
        rows
      end
    end
  end

  setup do
    @site = Workspace.create!(name: "Local heating").sites.create!(name: "Heating", location: "York",
      tracking_mode: "manual", host: "heating.test", rank_country_code: "GB")
    @site.keywords.create!(phrase: "Central Heating")
    @connection = @site.create_search_console_connection!(property: "sc-domain:heating.test", status: "connected",
      refresh_token: "fixture-grant", data_through: Date.new(2026, 11, 24))
    @client = Client.new
  end

  test "collects only closed weeks, caches receipts including unknown totals and adds the next final week incrementally" do
    travel_to Time.utc(2026, 11, 26, 12) do
      20.times { |i| @site.keywords.create!(phrase: "watch #{i}") }
      assert run_sync
      assert_equal 8 * 21 * 2, weeks.count
      assert_equal [Date.new(2026, 9, 28), Date.new(2026, 11, 16)], [weeks.minimum(:week_start), weeks.maximum(:week_start)]
      assert_equal 48, @client.requests.size
      assert @client.requests.all? { |p| p[:dataState] == "final" && p[:type] == "web" && p[:dimensionFilterGroups].first[:filters].first == {dimension: "country", operator: "equals", expression: "gbr"} }
      assert_equal 1, @client.refreshes
      desktop = weeks.find_by!(query: "central heating", device: "desktop")
      assert_equal [2, 12], [desktop.clicks, desktop.impressions]
      assert_equal ["https://heating.test/boilers", "https://heating.test/guide"], desktop.pages.pluck("url")
      assert_equal [nil, nil, []], weeks.find_by!(query: "central heating", device: "mobile").attributes.values_at("clicks", "impressions", "pages")
      assert run_sync
      assert_equal 48, @client.requests.size
    end
    travel_to Time.utc(2026, 12, 2, 12) do
      @connection.update!(data_through: Date.new(2026, 11, 29))
      assert run_sync
      assert_equal Date.new(2026, 11, 23), weeks.maximum(:week_start)
      assert_equal 54, @client.requests.size
    end
  end

  test "marks omitted out-of-scope pages partial and retries only affected receipts after a day" do
    travel_to Time.utc(2026, 11, 26, 12) do
      @client.unscoped = true
      assert run_sync
      assert_equal 8, weeks.where(partial: true, device: "mobile").count
      # PostgreSQL timestamps bulk inserts with its wall clock, outside travel_to.
      weeks.where(partial: true).update_all(updated_at: Time.current)
      assert weeks.where(device: "mobile").all? { |week| week.pages.empty? }
      assert run_sync
      assert_equal 16, @client.requests.size
    end
    travel_to Time.utc(2026, 11, 27, 13) do
      @client.unscoped = false
      assert run_sync
      assert_equal 32, @client.requests.size
      assert_empty weeks.where(partial: true)
    end
  end

  test "cached receipts update the preferred page and retire findings for removed terms without reading Google" do
    travel_to Time.utc(2026, 11, 26, 12) do
      keyword = @site.keywords.sole
      assert run_sync
      finding = SiteFinding.current.find_by!(site: @site, keyword: keyword)
      keyword.update!(preferred_url: "https://heating.test/boilers")
      assert run_sync
      assert_equal keyword.preferred_url, finding.reload.evidence["preferred_url"]
      keyword.destroy!
      assert_not run_sync
      assert_not finding.reload.active?
      assert_equal 16, @client.requests.size
    end
  end

  test "a full page response preserves separately reported clicks and marks the whole batch incomplete" do
    reader = SearchConsole::PageWeekReader.new(client: @client, host: @site.host, property: @connection.property,
      country: "GBR", token: -> { "fixture-access" })
    receipts = stub_const(SearchConsole::PageWeekReader, :PAGE_LIMIT, 1) do
      reader.read(["central heating"], Date.new(2026, 11, 16))
    end
    assert receipts.all? { |row| row[:partial] }
    assert_equal 2, receipts.first[:clicks]
    assert_equal ["https://heating.test/boilers"], receipts.first[:pages].pluck("url")
  end

  test "the daily importer queues a separate weekly reader only after a successful scoped import" do
    configured = Class.new { def self.configured? = true }
    importer = Class.new { def self.call(connection, scheduled:) = scheduled && connection.status == "connected" }
    stub_const(SearchConsole, :Client, configured) do
      stub_const(SearchConsole, :Synchronizer, importer) do
        assert_enqueued_with(job: CompetingPageSyncJob, args: [@connection.id]) do
          SearchConsoleSyncJob.perform_now(@connection.id, scheduled: true)
        end
        @connection.update!(status: "delayed")
        assert_no_enqueued_jobs { SearchConsoleSyncJob.perform_now(@connection.id, scheduled: true) }
      end
    end
  end

  test "quota failures retain prior data and leave standard Search Console health independent" do
    travel_to Time.utc(2026, 11, 26, 12) do
      assert run_sync
      @site.keywords.create!(phrase: "new search")
      @client.quota_error = true
      assert_not run_sync
      assert_equal 16, weeks.count
      assert_equal "connected", @connection.reload.status
      assert_match(/429/, @connection.page_week_error)
      failed_count = @client.requests.size
      assert_not run_sync
      assert_equal failed_count, @client.requests.size
    end
  end

  test "reselecting the property clears scope and cancels any matching in-flight writer before the next request" do
    travel_to Time.utc(2026, 11, 26, 12) do
      assert run_sync
      assert weeks.any?
      @site.keywords.create!(phrase: "new search")
      @client.on_read = -> { @connection.update!(property: "https://heating.test/") }
      assert_not run_sync
      assert_empty weeks
      assert_nil @connection.reload.page_week_sync_key
      assert_nil @connection.page_week_synced_at
    end
  end

  test "disconnect removes weekly evidence" do
    travel_to Time.utc(2026, 11, 26, 12) do
      assert run_sync
      assert weeks.any?
      @connection.destroy!
      assert_empty weeks
    end
  end

  private

  def run_sync
    SearchConsole::CompetingPageSync.call(@connection, client: @client)
  end

  def weeks
    SearchConsolePageWeek.where(site_id: @site.id)
  end
end
