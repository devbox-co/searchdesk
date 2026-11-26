require "test_helper"

class SearchConsoleSitemapTest < ActiveSupport::TestCase
  test "read-only endpoint and normalized totals preserve zero and pending downloads" do
    calls = []
    client = SearchConsole::Client.new
    client.define_singleton_method(:json_request) do |url, token:|
      calls << [url, token]
      {"sitemap" => [
        {"path" => "https://example.test/sitemap.xml", "errors" => "2", "warnings" => "3", "lastDownloaded" => "2026-11-23T10:30:01-08:00"},
        {"path" => "https://example.test/posts.xml", "isPending" => true}
      ]}
    end
    summary = SearchConsole::SitemapSummary.fetch(client: client, token: "fake", property: "sc-domain:example.test")
    assert_equal [["https://www.googleapis.com/webmasters/v3/sites/sc-domain%3Aexample.test/sitemaps", "fake"]], calls
    assert_equal ["available", 2, 2, 3, 1, "2026-11-23T18:30:01Z"], summary.values_at("status", "count", "errors", "warnings", "pending", "last_downloaded")
    assert_not_includes summary.to_s, "posts.xml"
  end

  test "malformed or denied sitemap collection cannot stand in for a zero count" do
    client = Object.new
    client.define_singleton_method(:sitemaps) { |**| [{"path" => "url", "errors" => "invalid"}] }
    result = SearchConsole::SitemapSummary.fetch(client: client, token: "fake", property: "sc-domain:example.test")
    assert_equal "unavailable", result["status"]
    assert_not result.key?("count")
    client.define_singleton_method(:sitemaps) { |**| raise GoogleReadOnly::Client::Error }
    result = SearchConsole::SitemapSummary.fetch(client: client, token: "fake", property: "sc-domain:example.test")
    assert_equal "unavailable", result["status"]
  end
end
