require "test_helper"

class CompetingPageArticleCheckTest < ActiveSupport::TestCase
  setup do
    @site = Workspace.create!(name: "Local team").sites.create!(name: "York Repair", host: "repair.example",
      location: "York, England, United Kingdom", tracking_mode: "manual", rank_country_code: "GB")
    @site.create_search_console_connection!(property: "sc-domain:repair.example", status: "connected")
    @keyword = @site.keywords.create!(phrase: "bike repairs")
    @home = "https://repair.example/"
    @article = "#{@home}old-guide/"
    @dest = "#{@home}bicycle-repairs/"
    evidence = {"query" => @keyword.phrase, "country" => "GBR", "device" => "mobile", "property" => "sc-domain:repair.example",
      "pages" => [@article,@home], "weeks" => [{"state" => "leader", "leader_url" => @home}]}
    @finding = SiteFinding.create!(site: @site, keyword: @keyword, kind: "competing_pages", level: "watch", active: true,
      fingerprint: "test", evidence: evidence)
    @google = {"status" => "target_not_seen", "keyword" => @keyword.phrase, "device" => "mobile", "coverage" => 20, "captured_at" => "2026-11-25T09:30:00Z",
      "observation_id" => 12, "other_result" => {"position" => 19, "url" => @article, "title" => "Bicycle repairs ...", "description" => "Our team repairs damaged bicycles ..."}}
    @hop = {"url" => @article, "location" => @dest, "status" => 301}
    @reader = ->(**) { {"page" => {"status" => "redirected", "url" => @article, "redirects" => [@hop],
      "destination" => {"status" => "observed","http_status" => 200,"url" => @dest,"canonical" => @dest, "title" => "Bicycle repairs", "paragraphs" => ["sample"]}},
      "link" => {"outcome" => "source_redirected"}} }
    refresh_home
  end

  def refresh_home
    page = ->(**) { {"status" => "observed", "url" => @home, "title" => "York Repair", "description" => "Visit our workshop."} }
    CompetingPages::ListingCheck.new(@finding, listing_reader: ->(**) { @google }, page_reader: page).run(@finding.updated_at.iso8601(6))
  end

  def capture
    CompetingPages::ArticleCheck.candidate(@finding).fetch("capture_key")
  end

  def run_check(key: capture, reader: @reader)
    CompetingPages::ArticleCheck.call(finding: @finding, version: @finding.updated_at.iso8601(6), capture_key: key, reader:)
  end

  def archive(date, id: "archive", url: @article)
    @site.source_snapshots.create!(provider: CompetingPages::ArticleArchive::PROVIDER, external_id: id, source_url: url, observed_on: Date.parse(date),
      title: "Archived document", scope: "Public article", metrics: {"format" => "public_page_v1", "final_url" => url, "http_status" => 200,
        "captured_at" => date, "description" => "Other metadata.", "title" => "Bicycle repairs in York", "article_text" => "Our team repairs damaged bicycles each week.",
        "prior_redirect" => @hop.merge("captured_at" => "2026-11-09T09:05:00Z")})
  end

  test "redirect retains distinct archived, Google and current metadata after refreshing the homepage" do
    archive("2026-11-08T09:00:00Z")
    archive("2026-11-26T08:00:00Z", id: "after-search")
    report = run_check
    assert_equal %w[not_comparable not_comparable], report["comparison"].values
    assert_equal %w[truncated different], report.dig("archive", "comparison").values
    assert_equal true, report.dig("archive", "snippet_in_body")
    assert_equal 301, report.dig("archive", "prior_redirect", "status")
    assert_includes report.dig("draft","instructions"), "archived article body"
    assert_nil report.dig("page", "destination", "paragraphs")
    assert_equal "target_not_seen", @finding.reload.listing_check.dig("google","status")
    assert_equal report, CompetingPages::ArticleCheck.saved(@finding)
    refresh_home
    assert_equal report, CompetingPages::ArticleCheck.saved(@finding.reload)
  end

  test "wrong host, out-of-range rank, edited settings or swapped device never start an article check" do
    original = capture
    @google["other_result"]["position"] = 25
    refresh_home
    assert_nil CompetingPages::ArticleCheck.candidate(@finding)
    @google["other_result"].merge!("position" => 10, "url" => "https://another.example/article")
    refresh_home
    assert_nil CompetingPages::ArticleCheck.candidate(@finding)
    @google["other_result"]["url"] = @article
    refresh_home
    assert_raises(CompetingPages::ArticleCheck::Stale) { run_check(key: original, reader: ->(**) { flunk "Stale receipt fetched" }) }
    @google["device"] = "desktop"
    refresh_home
    assert_nil CompetingPages::ArticleCheck.candidate(@finding)
    @site.search_console_connection.update!(status: "reconnect")
    assert_nil CompetingPages::ArticleCheck.candidate(@finding.reload)
  end

  test "broken redirect evidence, an unrelated archive and missing fields never become an exact match" do
    archive("2026-11-08T09:00:00Z", id: "destination-archive", url: @dest)
    assert_nil run_check["archive"]
    a = archive("2026-11-07T09:00:00Z")
    a.update!(metrics: a.metrics.merge("description" => nil, "article_text" => "", "prior_redirect" => @hop.merge("location" => @home)))
    result = run_check["archive"]
    assert_equal "not_comparable", result.dig("comparison", "description")
    assert_not result["snippet_in_body"]
    assert_nil result["prior_redirect"]
    assert_nil result["matched_passage"]
  end

  test "published text and the displayed listing are compared field by field only for the article itself" do
    report = run_check(reader: ->(**) { {"page" => {"url" => @article, "status" => "observed", "title" => "Bicycle repairs in York",
      "description" => "Different words"}, "link" => {"outcome" => "missing"}} })
    assert_equal %w[truncated different], report["comparison"].values
    assert_nil report["archive"]
  end
end
