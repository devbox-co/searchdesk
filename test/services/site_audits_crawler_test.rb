require "test_helper"

class SiteAuditsCrawlerTest < ActiveSupport::TestCase
  def response(status: 200, body: "", type: "text/html", to: nil, directives: "")
    SiteAudits::Fetcher::Response.new(status, to, type, directives, body)
  end

  def crawl(routes)
    @requests = []
    @waits = []
    fetcher = Object.new
    timeline = @requests
    fetcher.define_singleton_method(:get) do |uri, robots: false|
      timeline << uri.to_s
      routes.fetch(uri.to_s) { routes.fetch(uri.path) { raise "Unplanned request #{uri.path}" } }
    end
    SiteAudits::Crawler.new(host: "example.test", fetcher: fetcher, sleeper: ->(s) { @waits << s }).call
  end

  test "summary and page findings come from fetched HTML, response headers and internal links" do
    links = %w[/a /broken /removed /moved /offsite /hidden /wp-admin/ /assets.jpg /duplicate?q=123 //another.test/].map { |u| %(<a href="#{u}">next</a>) }.join
    html = "<html><head><title>My business</title></head><body><h1>Main</h1>#{links}<form action='/submit'></form></body></html>"
    report = crawl("/robots.txt" => response(body: "User-agent: *\nDisallow: /hidden\nCrawl-delay: 1"),
      "/" => response(body: html), "/a" => response(body: '<html><head><title>My business</title><meta name="robots" content="noindex"></head><body></body></html>'),
      "/broken" => response(status: 404), "/removed" => response(status: 410),
      "/moved" => response(status: 301, to: "/a"), "/offsite" => response(status: 302, to: "https://another.test/foo"))
    assert_equal "complete", report["status"]
    stats = report.fetch("summary")
    assert_equal [6, 2, 2, 2, 1, 7], stats.values_at("pages_checked", "html_pages", "redirects", "http_errors", "robots_blocked", "request_count")
    assert @requests.all? { |u| u.start_with?("https://example.test/") }
    assert @waits.all? { |delay| delay >= 1 }
    home = report["pages"].find { |p| p["path"] == "/" }
    assert_equal ["/broken", "/removed"], home["broken_links"]
    assert_equal 6, home["internal_links"]
    assert_includes home["issues"], "duplicate_title"
    assert_includes report["pages"].find { |p| p["path"] == "/a" }["issues"], "noindex"
    assert_equal ["/offsite"], report["issues"].find { |i| i["code"] == "redirect_unfollowed" }["paths"]
  end

  test "checked page count is bounded even when the homepage links to hundreds of URLs" do
    references = (1..500).map { |i| %(<a href="/p#{i}">page</a>) }.join
    routes = { "/robots.txt" => response(status: 404), "/" => response(body: references) }
    (1..20).each { |i| routes["/p#{i}"] = response(body: "<h1>Other page</h1>") }
    report = crawl(routes)
    assert_equal 20, report.dig("summary", "pages_checked")
    assert_equal 21, @requests.size
    assert_equal 400, report.dig("summary", "discovered_urls")
    assert_equal "complete", report["status"]
    assert_match(/20-URL sample/, report["stop_reason"])
  end

  test "unavailable or disallowing robots rules never fetch the homepage" do
    [response(status: 503), response(body: "User-agent: *\nDisallow: /"), response(status: 301, to: "https://other.test/robots.txt")].each do |gate|
      result = crawl("/robots.txt" => gate)
      assert_equal "failed", result["status"]
      assert_equal 0, result.dig("summary", "pages_checked")
      assert_equal ["https://example.test/robots.txt"], @requests
    end
  end

  test "a robots redirect stays in scope and a changed origin must pass its own robots check" do
    report = crawl("/robots.txt" => response(status: 301, to: "/policy.txt"),
      "/policy.txt" => response(body: "User-agent: *\nAllow: /"),
      "/" => response(status: 301, to: "https://www.example.test/landing"),
      "https://www.example.test/robots.txt" => response(body: "User-agent: *\nDisallow: /landing"))
    assert_equal ["https://example.test/robots.txt", "https://example.test/policy.txt", "https://example.test/", "https://www.example.test/robots.txt"], @requests
    assert_equal 1, report.dig("summary", "robots_blocked")
  end

  test "XHTML and scoped header directives are evaluated using their own markup and agent" do
    markup = '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Useful title</title></head><body><h1>Page</h1></body></html>'
    report = crawl("/robots.txt" => response(status: 404),
      "/" => response(body: markup, type: "application/xhtml+xml", directives: "OtherBot: noindex"))
    page = report["pages"].sole
    assert_equal "Useful title", page["title"]
    assert_equal 1, page["h1_count"]
    assert_not_includes page["issues"], "noindex"
  end

  test "read-only robots policy respects product agent groups, wildcard specificity, anchors and escaped letters" do
    policy = SiteAudits::Robots.new(<<~TXT)
      User-agent: *
      Disallow: /
      User-agent: SearchdeskBot
      Disallow: /secret*
      Allow: /secret/help$
      Disallow: /café
      User-agent: SearchdeskBot
      Disallow: /archive/
    TXT
    assert policy.allowed?("/home")
    assert policy.allowed?("/secret/help")
    assert_not policy.allowed?("/s%65cret/help-more")
    assert_not policy.allowed?("/archive/one")
    assert_not policy.allowed?("/caf%C3%A9")
  end

  test "only owned public http destinations enter the crawl and special address ranges stay excluded" do
    scope = SiteAudits::PublicUrl.new("example.test")
    base = "https://example.test/"
    assert_equal "https://www.example.test/services", scope.resolve("https://www.example.test/services#prices", base: base).to_s
    %w[http://external.test/path https://example.test:8000/path https://name@example.test/path /some?session=2 /wp-json/
       /%77p-admin/private /a%2fb%2f%2eprivate /s/%2e/item /s/%2e%2e/item /%252e%252e/secret /cart/ /file.jpg data:text/plain,example].each do |u|
      assert_nil scope.resolve(u, base: base), u
    end
    %w[127.0.0.1 10.0.0.1 100.64.0.1 169.254.30.4 192.0.2.5 224.0.0.1 ::1 fd00::1 fe80::abcd ::ffff:127.0.0.1 2001:db8::1 2002:7f00::1].each do |ip|
      assert_not SiteAudits::PublicUrl.public_ip?(ip), ip
    end
    assert SiteAudits::PublicUrl.public_ip?("8.8.8.8")
    assert SiteAudits::PublicUrl.public_ip?("2606:4700:4700::1111")
  end
end
