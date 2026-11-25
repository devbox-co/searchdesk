require "test_helper"

class ProviderContractTest < ActiveSupport::TestCase
  class FixtureProvider < Tracking::DataForSeo
    attr_accessor :fixture
    attr_reader :requests

    def initialize
      @requests = []
    end

    def locations(_country)
      [{ "location_code" => 11, "location_name" => "North Town,East,United Kingdom", "country_iso_code" => "GB" },
       { "location_code" => 12, "location_name" => "North Town,West,United Kingdom", "country_iso_code" => "GB" },
       { "location_code" => 41, "location_name" => "North Town,West,United States", "country_iso_code" => "US" }]
    end

    private

    def request(method, path, payload = nil, **options)
      @requests << [method, path, payload]
      fixture
    end
  end

  test "country catalogue matches exact official names or asks for the full name without spending a SERP task" do
    fake = FixtureProvider.new
    err = assert_raises(Tracking::LocationResolver::Error) { Tracking::LocationResolver.resolve!(name: "north town", country: "gb", client: fake) }
    assert_match "North Town,East,United Kingdom", err.message
    answer = Tracking::LocationResolver.resolve!(name: "North Town, WEST , United Kingdom", country: "GB", client: fake)
    assert_equal [12, "North Town,West,United Kingdom"], answer.values_at(:rank_location_code, :rank_location_name)
    assert_raises(Tracking::LocationResolver::Error) { Tracking::LocationResolver.resolve!(name: "North Town,West,United Kingdom", country: "GB", expected_code: 11, client: fake) }
    assert_empty fake.requests
  end

  test "confirmed provider response must belong to the task and exact series, and carries its actual capture time" do
    site = Workspace.create!(name: "Team").sites.create!(name: "Business", host: "sample.test", tracking_mode: "dataforseo",
      location: "North Town,West,United Kingdom", language: "en", time_zone: "UTC", rank_country_code: "GB", rank_location_code: 12,
      rank_location_name: "North Town,West,United Kingdom", rank_location_verified_at: Time.current)
    series = Tracking::Enrollment.call(site: site, phrase: "heating", devices: ["mobile"]).tracking_series.first
    slot = series.daily_slots.sole
    slot.update!(task_id: SecureRandom.uuid, attempt_key: SecureRandom.uuid, attempted_at: Time.current)
    provider = FixtureProvider.new
    stamp = Time.current.utc.change(usec: 0)
    items = [{ "type" => "organic", "rank_group" => 1, "url" => "https://sample.test/" }]
    task = { "id" => slot.task_id, "status_code" => 20000, "data" => { "device" => "mobile", "os" => "android",
      "se" => "google", "se_type" => "organic", "tag" => slot.attempt_key }, "result" => [{ "keyword" => "heating",
      "location_code" => 12, "language_code" => "en", "datetime" => stamp.iso8601, "items" => items }] }
    provider.fixture = { "tasks" => [task] }
    parsed = provider.poll(slot)
    assert_equal stamp, parsed[:captured_at]
    assert_equal slot.task_id, parsed[:reference]
    result = Tracking::RecordResult.call(series: series, expected_day: slot.day, **parsed)
    assert_equal [1, "dataforseo"], [result.position, result.source]
    task["data"]["device"] = "desktop"
    assert_raises(Tracking::DataForSeo::ScopeError) { provider.poll(slot) }
    assert provider.requests.all? { |(method, _, _)| method == :get }
  end

  test "standard organic submission limits crawling to three pages without billable extras" do
    provider = FixtureProvider.new
    id = SecureRandom.uuid
    provider.fixture = {"tasks" => [{"status_code" => 20100, "id" => id}]}
    settings = {"keyword" => "repairs", "location_code" => 123, "language" => "en", "device" => "desktop", "os" => "windows"}
    slot = Struct.new(:tracking_series, :attempt_key).new(Struct.new(:settings).new(settings), SecureRandom.uuid)
    assert_equal id, provider.submit(slot)
    assert_equal [[:post, "/v3/serp/google/organic/task_post", [{
      keyword: "repairs", location_code: 123, language_code: "en", device: "desktop", os: "windows",
      depth: 30, max_crawl_pages: 3, priority: 1, tag: slot.attempt_key
    }]]], provider.requests
    ["SITE:example.test", "%73ite%3Aexample.test", "service intitle:offers"].each do |keyword|
      settings["keyword"] = keyword
      assert_raises(Tracking::DataForSeo::Rejected) { provider.submit(slot) }
    end
    assert_equal 1, provider.requests.size
  end
end
