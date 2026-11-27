require "test_helper"

class ListingEvidenceTest < ActiveSupport::TestCase
  setup do
    @site = Workspace.create!(name: "Listing example").sites.create!(name: "Heating", host: "heating.example", location: "York",
      time_zone: "Europe/London", tracking_mode: "dataforseo", rank_location_code: 100,
      rank_location_name: "York", rank_location_verified_at: Time.current)
    @url = "https://heating.example/"
    @stamp = Time.current.change(usec: 0)
    travel_to(@stamp - 2.days) do
      @keyword = Tracking::Enrollment.call(site: @site, phrase: "heating york", preferred_url: @url)
    end
    @series = @keyword.tracking_series.find_by!(device: "mobile")
  end

  def record(rows, day: @stamp, series: @series)
    Tracking::RecordResult.call(series:, captured_at: day, items: rows, reference: "10000000-abcd-1234-abcd-100000000000",
      metadata: { Tracking::ListingEvidence::KEY => [{ "url" => "fabricated" }] })
  end

  def lookup(url = @url, device: "mobile", provider: nil)
    Tracking::ListingEvidence.call(keyword: @keyword, device:, url:, provider:)
  end

  def item(position, url, title: nil, snippet: nil, type: "organic")
    { "type" => type, "rank_group" => position, "url" => url, "title" => title, "description" => snippet }
  end

  test "saves exact source words for the verified own url and rejects devices, domains and market changes" do
    text = "Useful advice\u00a0..."
    rows = [
      item(1, "https://unrelated.example/"), item(2, @url, title: "York & home...", snippet: text),
      item(3, "https://heating.example/help", title: "More"),
      item(4, @url, title: "Ad", type: "paid"), item(7, @url, title: "After gap")
    ]
    reading = record(rows)
    assert_equal [2, 3], reading.evidence.fetch(Tracking::ListingEvidence::KEY).pluck("position")
    result = lookup
    assert_equal ["observed", "York & home...", text, @stamp.utc.iso8601, 2, 3, @url, "York", "en", "mobile"],
      result.values_at("status", "title", "description", "captured_at", "position", "coverage", "url", "location", "language", "device")
    assert_nil lookup("https://heating.example/help")["description"]
    assert_equal "unavailable", lookup(device: "desktop")["status"]
    assert_equal "unavailable", lookup("https://competitor.example/")["status"]
    assert_equal "unavailable", lookup("https://heating.example/?email=personal")["status"]
    assert_equal "target_not_seen", lookup("https://www.heating.example/")["status"]
    @site.update!(language: "fr")
    assert_equal "unavailable", lookup["status"]
  end

  test "latest page absence retains other observed result and labels an older exact match separately" do
    record([item(1, @url, title: "Earlier homepage")], day: @stamp - 1.day)
    record([item(1, @url, title: "Desktop homepage")], series: @keyword.tracking_series.find_by!(device: "desktop"))
    record([item(1, "https://heating.example/article", title: "An article"), item(2, "https://other.example/")])
    result = lookup
    assert_equal ["target_not_seen", 2, nil, nil], result.values_at("status", "coverage", "title", "url")
    assert_equal ["https://heating.example/article", 1, "An article"], result.fetch("other_result").values_at("url", "position", "title")
    assert_equal ["Earlier homepage", (@stamp - 1.day).utc.iso8601, @url], result.fetch("previous_result").values_at("title", "captured_at", "url")
  end

  test "re-reads a bound existing receipt once and rejects mismatched capture or unverified positions" do
    rows = [item(1, "https://heating.example/article", title: "Article"), item(2, @url, title: "Google title")]
    reading = record(rows)
    reading.update!(evidence: reading.evidence.except(Tracking::ListingEvidence::KEY))
    slot = reading.daily_slot
    slot.update!(task_id: reading.evidence.fetch("reference"))
    provider = Struct.new(:response) { def poll(_slot) = response }.new
    payload = { items: rows, reference: slot.task_id, captured_at: @stamp }
    provider.response = payload.merge(captured_at: @stamp - 1.minute)
    assert_equal "unavailable", lookup(provider:)["status"]
    provider.response = payload.merge(items: rows.reverse.drop(1))
    assert_equal "unavailable", lookup(provider:)["status"]
    refute reading.reload.evidence.key?(Tracking::ListingEvidence::KEY)
    provider.response = payload
    assert_equal "Google title", lookup(provider:)["title"]
    assert_equal "Google title", lookup["title"]
  end

  test "an empty contiguous capture gives no absence claim" do
    assert_equal "unavailable", lookup["status"]
    record([item(2, @url, title: "Unverified rank")])
    assert_equal "unavailable", lookup["status"]
  end

  test "an unbound or wrong-source receipt cannot supply a Google listing" do
    reading = record([item(1, @url)])
    reading.update!(evidence: reading.evidence.except(Tracking::ListingEvidence::KEY))
    assert_equal "unavailable", lookup["status"]
    reading.update!(source: "manual")
    assert_equal "unavailable", lookup["status"]
  end
end
