require "test_helper"

class ArticlePageTest < ActiveSupport::TestCase
  HOME = "https://example.test/"
  ARTICLE = HOME + "guide/"
  SERVICE = HOME + "consultation/"

  def response(body = "", status: 200, location: nil)
    SiteAudits::Fetcher::Response.new(status, location, "text/html", "", body)
  end

  def inspect_article(body = "", routes: {}, url: ARTICLE)
    @requests = []
    visits = @requests
    pages = {HOME + "robots.txt" => response(status: 404), ARTICLE => response(body), HOME => response("<h1>Clinic homepage</h1>")}.merge(routes)
    fetcher = Object.new
    fetcher.define_singleton_method(:get) do |uri, robots: false|
      visits << uri.to_s
      pages.fetch(uri.to_s)
    end
    SiteAudits::ArticlePage.call(host: "example.test", url: url, homepage: HOME, fetcher: fetcher, sleeper: ->(_) {})
  end

  test "records a historical article's entire redirect chain and keeps the current destination tags separate" do
    old = HOME + "old/"
    result = inspect_article(routes: {ARTICLE => response(status: 301, location: "/old/"),
      old => response(status: 302, location: SERVICE),
      SERVICE => response('<title>Consultations</title><meta name="description" content="Team and prices"><link rel="canonical" href="/consultation/"><div class="hentry"><h1>Our team</h1><h2>Consultation prices</h2><p>Read our <a href="/">homepage</a> for more.</p></div>')})
    page, link = result.values_at("page", "link")
    assert_equal ["redirected", ARTICLE], page.values_at("status", "url")
    assert_nil page["title"]
    assert_nil page["description"]
    assert_equal [{"url" => ARTICLE, "status" => 301, "location" => old}, {"url" => old, "status" => 302, "location" => SERVICE}], page["redirects"]
    assert_equal ["observed", SERVICE, 200, SERVICE, "Consultations", "Team and prices", ["Consultation prices"]],
      page["destination"].values_at("status", "url", "http_status", "canonical", "title", "description", "headings")
    assert_equal "source_redirected", link["outcome"]
    assert_equal [HOME + "robots.txt", ARTICLE, old, SERVICE], @requests
  end

  test "missing destination leaves a redirect and its HTTP error visible without fabricating article copy" do
    result = inspect_article(routes: {ARTICLE => response(status: 308, location: SERVICE), SERVICE => response(status: 404)})
    assert_equal 308, result.dig("page", "redirects", 0, "status")
    assert_equal ["unavailable", 404], result.dig("page", "destination").values_at("status", "http_status")
    assert_match(/404/, result.dig("page", "destination", "reason"))
    assert_equal "source_redirected", result.dig("link", "outcome")
  end

  test "reads exact article tags, body and contextual homepage link in one source request" do
    intro = "Read our complete guide to choosing a local service."
    result = inspect_article(<<~HTML)
      <html><head><title>Town guide</title><meta name="description" content="An independent guide"></head><body>
      <nav><a href="/">Homepage</a></nav><article><div class="entry-meta"><p>Here are some unrelated words about the publisher.</p></div>
      <div class="entry-content"><h1>Town guide</h1><p>By J.</p><p>#{intro}</p><h2>Visiting us</h2>
      <p>Visit <a href="/">our clinic homepage</a> to discover what happens next.</p></div></article></body></html>
    HTML
    page, link = result.values_at("page", "link")
    assert_equal ["observed", "Town guide", "An independent guide", intro], page.values_at("status", "title", "description", "opening"), result.inspect
    assert_equal [intro, "Visit our clinic homepage to discover what happens next."], page["paragraphs"]
    assert_equal ["contextual", "our clinic homepage", "Visiting us", HOME], link.values_at("outcome", "anchor", "section", "linked_url")
    assert_equal [HOME + "robots.txt", ARTICLE, HOME], @requests
  end

  test "post metadata and author links cannot be mistaken for editorial homepage links" do
    result = inspect_article('<article><h1>Article</h1><div class="entry-meta"><p>See the <a href="/">author biography</a> for details.</p></div><p>Actual article text describes how to find a city shop.</p></article>')
    assert_equal ["navigation_only", "Post details", "author biography"], result["link"].values_at("outcome", "placement", "anchor")
    assert_equal ["Actual article text describes how to find a city shop."], result.dig("page", "paragraphs")
    result = inspect_article('<main><div class="entry-content"><p>Actual article text describes how to find a city shop.</p></div><a rel="author" href="/">Owner</a></main>')
    assert_equal "navigation_only", result.dig("link", "outcome")
  end

  test "template menus and unlabelled standalone links do not establish an editorial link" do
    body = '<main><div class="wp-block-navigation"><p>This paragraph describes menu options.</p><a href="/">Home</a></div><p>This paragraph is the local travel guide introduction.</p></main>'
    result = inspect_article(body)
    assert_equal ["navigation_only", "Navigation"], result["link"].values_at("outcome", "placement")
    assert_equal "This paragraph is the local travel guide introduction.", result.dig("page", "opening")
    result = inspect_article('<article><div><a href="/">Logo</a></div><p>The local travel guide gives details of the area.</p></article>')
    assert_equal "unverifiable", result.dig("link", "outcome")
  end

  test "an absent link requires a single identifiable body and a reachable homepage" do
    article = '<article><h1>City walking tours</h1><p>Weekly walks start by the market square.</p></article>'
    assert_equal "missing", inspect_article(article).dig("link", "outcome")
    result = inspect_article(article * 2)
    assert_nil result.dig("page", "opening")
    assert_equal "unverifiable", result.dig("link", "outcome")
    result = inspect_article(article, routes: {HOME => response(status: 500)})
    assert_equal "observed", result.dig("page", "status")
    assert_equal "unverifiable", result.dig("link", "outcome")
  end

  test "a redirect outside owned public pages is not followed and cannot establish any original title" do
    result = inspect_article(routes: {ARTICLE => response(status: 302, location: "https://outside.test/")})
    assert_equal "unavailable", result.dig("page", "status")
    assert_nil result.dig("page", "title")
    assert_equal [HOME + "robots.txt", ARTICLE], @requests
  end
end
