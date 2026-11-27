require "test_helper"

class TargetedLinkCheckTest < ActiveSupport::TestCase
  SITE = "https://example.test"
  SOURCE = "#{SITE}/advice/"
  TARGET = "#{SITE}/service/"

  def response(body = "", status: 200, location: nil, type: "text/html")
    SiteAudits::Fetcher::Response.new(status, location, type, "", body)
  end

  def run_check(body, routes: {}, source_url: SOURCE, target_url: TARGET)
    @requests = []
    @waits = []
    pages = {
      "#{SITE}/robots.txt" => response(status: 404),
      SOURCE => response(body),
      TARGET => response("<h1>Local boiler servicing</h1>")
    }.merge(routes)
    requests = @requests
    fetcher = Object.new
    fetcher.define_singleton_method(:get) do |uri, robots: false|
      requests << uri.to_s
      pages.fetch(uri.to_s)
    end
    SiteAudits::TargetedLinkCheck.new(host: "example.test", source_url: source_url,
      target_url: target_url, fetcher: fetcher, sleeper: ->(seconds) { @waits << seconds }).call
  end

  test "chooses the contextual link over earlier navigation and records its nearest heading" do
    result = run_check(<<~HTML)
      <nav><a href="/service/">Services</a></nav>
      <article><h1>Winter advice</h1><h2>When to book</h2>
      <p>Read about <a href="../service/#times">local <b>boiler servicing</b></a> before booking.</p></article>
      <footer><a href="/service/">All services</a></footer>
    HTML
    assert_equal ["contextual", "local boiler servicing", "When to book", "Article text", TARGET, 200],
      result.values_at("outcome", "anchor", "section", "placement", "final_target_url", "target_status")
    assert_equal ["#{SITE}/robots.txt", SOURCE, TARGET], @requests
  end

  test "returns a footer or sidebar link separately from the main text" do
    { "footer" => "Footer", "aside" => "Sidebar", "nav" => "Navigation" }.each do |tag, placement|
      result = run_check("<article><p>Call the workshop to schedule your service.</p></article><#{tag}><a href='/service/'>Our services</a></#{tag}>")
      assert_equal ["navigation_only", "Our services", placement], result.values_at("outcome", "anchor", "placement")
    end
  end

  test "public HTML with readable prose and no direct link distinguishes a missing link from hidden links" do
    result = run_check(<<~HTML)
      <main><p>There are appointments throughout the week.</p></main>
      <div hidden><a href="/service/">Old copy</a></div>
      <div style="display: none;"><a href="/service/">Old offer</a></div>
      <template><a href="/service/">Template link</a></template>
      <nav><a href="https://other.test/service/">Another business</a></nav>
    HTML
    assert_equal "missing", result["outcome"]
    assert_nil result["anchor"]
  end

  test "resolves a declared base, proves redirect aliases and respects a second origin's robots policy" do
    result = run_check('<html><head><base href="/directory/"></head><body><main><p>Choose <a href="new/">servicing</a> for your area.</p></main></body></html>',
      routes: {TARGET => response(status: 301, location: "/directory/new/"),
        "#{SITE}/directory/new/" => response(status: 302, location: "https://www.example.test/services/new/"),
        "https://www.example.test/robots.txt" => response("User-agent: *\nCrawl-delay: 1"),
        "https://www.example.test/services/new/" => response("<h1>Service details</h1>")})
    assert_equal ["contextual", "#{SITE}/directory/new/", "https://www.example.test/services/new/"],
      result.values_at("outcome", "linked_url", "final_target_url")
    assert_equal 1, @waits.last
  end

  test "does not declare an unverified destination variant equivalent to the selected URL" do
    ["/service/?type=old", "/service", "http://example.test/service/", "https://www.example.test/service/"].each do |href|
      result = run_check("<main><p>Find details in our <a href='#{href}'>boiler service guide</a>.</p></main>")
      assert_equal "unverifiable", result["outcome"], href
      assert_match(/possible link/, result["reason"])
      assert_equal ["#{SITE}/robots.txt", SOURCE, TARGET], @requests
    end
  end

  test "unreadable and dynamically rendered pages do not support a missing link claim" do
    ["<main id='root'></main><script>draw()</script>",
      "<nav><a href='/service/'>Services</a></nav><div id='root'>Loading…</div>",
      "<title>Just a moment...</title><p>Please verify that you are human before proceeding.</p>"].each do |body|
      assert_equal "unverifiable", run_check(body)["outcome"]
    end
    result = run_check("<main><p>See our <a href='/service/'>servicing</a> for details.</p></main>",
      routes: {TARGET => response("<main>Please enable JavaScript to view this page.</main>")})
    assert_equal "unverifiable", result["outcome"]
    assert_match(/chosen page/, result["reason"])
  end

  test "requires a live destination and distinguishes a missing page from temporary errors" do
    [404, 410, 403, 429, 500].each do |status|
      result = run_check("<article><a href='/service/'>Servicing</a></article>", routes: {TARGET => response(status: status)})
      assert_equal([404, 410].include?(status) ? "broken_target" : "unverifiable", result["outcome"])
      assert_equal status, result["target_status"]
    end
  end

  test "refuses redirects to excluded pages, circular redirects and both pages redirecting to one" do
    ["https://other.test/elsewhere", "/wp-admin/", TARGET].each do |location|
      result = run_check("<h1>Advice</h1>", routes: {TARGET => response(status: 301, location: location)})
      assert_equal "unverifiable", result["outcome"]
      assert_equal ["#{SITE}/robots.txt", SOURCE, TARGET], @requests
    end
    result = run_check("<h1>Advice</h1>", routes: {SOURCE => response(status: 302, location: "/service/")})
    assert_equal "unverifiable", result["outcome"]
    assert_match(/same page/, result["reason"])
  end

  test "rejects out-of-scope input, respects robots rules, time budget and page redirect limits" do
    result = run_check("", source_url: "https://unrelated.test/advice/")
    assert_equal "unverifiable", result["outcome"]
    assert_empty @requests
    result = run_check("<h1>Advice</h1>", routes: {"#{SITE}/robots.txt" => response("User-agent: *\nDisallow: /service/")})
    assert_equal "unverifiable", result["outcome"]
    assert_equal ["#{SITE}/robots.txt", SOURCE], @requests
    result = run_check("", routes: {"#{SITE}/robots.txt" => response("User-agent: *\nCrawl-delay: 30")})
    assert_equal "unverifiable", result["outcome"]
    assert_equal ["#{SITE}/robots.txt"], @requests
    routes = {SOURCE => response(status: 301, location: "/r0/")}
    3.times { |i| routes["#{SITE}/r#{i}/"] = response(status: 302, location: "/r#{i+1}/") }
    result = run_check("", routes: routes)
    assert_equal "unverifiable", result["outcome"]
    assert_match(/too many redirects/, result["reason"])
    assert_not_includes @requests, "#{SITE}/r3/"
  end
end
