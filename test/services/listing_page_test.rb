require "test_helper"

class ListingPageTest < ActiveSupport::TestCase
  HOME = "https://example.test/"
  WWW = "https://www.example.test/"

  def response(body = "", status: 200, location: nil, type: "text/html")
    SiteAudits::Fetcher::Response.new(status, location, type, "", body)
  end

  def review(html: "", routes: {}, url: HOME)
    pages = { HOME + "robots.txt" => response(status: 404), HOME => response(html) }.merge(routes)
    requests = @requests = []
    reader = Object.new
    reader.define_singleton_method(:get) do |uri, robots: false|
      requests << uri.to_s
      pages.fetch(uri.to_s)
    end
    SiteAudits::ListingPage.call(host: "example.test", url: url, fetcher: reader, sleeper: ->(_) {})
  end

  test "reads actual head fields, visible heading and bounded paragraph evidence at the effective URL" do
    content = <<~HTML
      <html><head><title>Thé &amp; Café</title><meta property="og:description" content="Social copy">
      <meta name="DeScRiPtIoN" content="Venez déguster l’été &amp; ses fruits."></head><body>
      <h1 hidden>Hidden headline</h1><h1>Goûtez nos <b>pâtisseries</b></h1><h2>Nos spécialités</h2><nav><h2>Menu</h2></nav>
      <script>Bad script</script><footer><p>Irrelevant footer paragraph longer than thirty-five characters.</p></footer>
      <p>Découvrez les saveurs de la saison dans notre café.</p></body></html>
    HTML
    travel_to Time.utc(2026, 11, 26, 8, 12, 32) do
      result = review(routes: { HOME => response(status: 301, location: WWW), WWW + "robots.txt" => response(status: 404), WWW => response(content.b) })
      assert_equal ["observed", WWW, "Thé & Café", "Venez déguster l’été & ses fruits.", "Goûtez nos pâtisseries", "2026-11-26T08:12:32Z"],
        result.values_at("status", "url", "title", "description", "h1", "checked_at")
      assert_equal ["Nos spécialités"], result["headings"]
      assert_equal ["Découvrez les saveurs de la saison dans notre café."], result["excerpts"]
      assert_equal ["present", "present", "present"], result["field_states"].values_at("title", "description", "h1")
    end
    assert_equal [HOME + "robots.txt", HOME, WWW + "robots.txt", WWW], @requests
  end

  test "qualifies empty, missing, duplicated and oversized fields rather than presenting substitutes as exact copy" do
    result = review(html: '<html><head><title> </title><meta name="description" content="One"><meta name="DESCRIPTION" content="Two"></head><body><p>Site homepage</p></body></html>')
    assert_equal "observed", result["status"]
    assert_equal [nil, nil, nil], result.values_at("title", "description", "h1")
    assert_equal ["empty", "multiple", "missing"], result["field_states"].values_at("title", "description", "h1")
    result = review(html: "<title>#{'A' * 2001}</title><h1>One</h1><h1>Two</h1>")
    assert_equal ["too_long", "missing", "multiple"], result["field_states"].values_at("title", "description", "h1")
  end

  test "honours a legacy page's declared charset" do
    page = '<html><head><meta charset="windows-1252"><title>Café</title></head><body><h1>Café</h1></body></html>'.encode("Windows-1252").b
    assert_equal "Café", review(html: page)["title"]
  end

  test "cannot present challenge pages or absent, erroneous or non-HTML responses as the homepage" do
    [response("<title>Just a moment...</title><p>Please verify you are human.</p>"),
      response("<title>The site</title><body><script>render()</script></body>"),
      response("error", status: 503), response("file", type: "application/pdf")].each do |reply|
      result = review(routes: { HOME => reply })
      assert_equal "unavailable", result["status"]
      assert_predicate result["reason"], :present?
      assert_nil result["title"]
    end
  end

  test "checks robots and every redirect against the public HTTPS website scope" do
    ["https://different.test/", "http://example.test/", HOME + "?token=secret", HOME + "wp-admin/"].each do |bad|
      assert_equal "unavailable", review(url: bad)["status"]
      assert_empty @requests
      assert_equal "unavailable", review(routes: { HOME => response(status: 301, location: bad) })["status"]
      assert_equal [HOME + "robots.txt", HOME], @requests
    end
    assert_equal "unavailable", review(routes: { HOME + "robots.txt" => response("User-agent: *\nDisallow: /") })["status"]
    assert_equal [HOME + "robots.txt"], @requests
    assert_equal "unavailable", review(routes: { HOME + "robots.txt" => response(status: 302, location: "http://example.test/robots.txt") })["status"]
    assert_equal [HOME + "robots.txt"], @requests
  end
end
