require "test_helper"
require "active_support/testing/constant_stubbing"

class CompetingPagesTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::ConstantStubbing

  setup do
    workspace = Workspace.create!(name: "Westbridge")
    @site = workspace.sites.create!(name: "Westbridge", host: "westbridge.example", location: "York", rank_country_code: "GB")
    @keyword = @site.keywords.create!(phrase: "boiler servicing")
    @property = "sc-domain:westbridge.example"
    @connection = @site.create_search_console_connection!(property: @property, status: "connected")
    @urls = %w[https://westbridge.example/guide/ https://westbridge.example/servicing/]
    user = User.create!(email: "page-owner@example.test", password: "long-local-test-password")
    @membership = workspace.memberships.create!(user: user, role: "owner")
    post login_path, params: { session: { email: user.email, password: "long-local-test-password" } }
  end

  test "actions links to the filtered review and detail explains the real lead history and site clicks" do
    finding = record_finding
    other = @site.keywords.create!(phrase: "heat pump")
    record_finding(query: other, level: "limited")
    get actions_path(keyword_id: @keyword.id)
    assert_select "a[href=?]", competing_pages_path(keyword_id: @keyword.id)
    get competing_pages_path(keyword_id: @keyword.id)
    assert_response :success
    assert_select "h2", text: /Review first/
    assert_select "a[href=?]", competing_page_path(finding, keyword_id: @keyword.id)
    assert_select ".cp-keyword", count: 1
    assert_no_enqueued_jobs do
      assert_no_changes -> { finding.reload.attributes } do
        get competing_page_path(finding, keyword_id: @keyword.id)
      end
    end
    assert_response :success
    assert_select "a[href=?]", competing_pages_path(keyword_id: @keyword.id)
    assert_select "h1", @keyword.phrase
    assert_select ".cp-source", /United Kingdom · Desktop/
    assert_select ".cp-summary a[href=?]", @urls.first
    assert_select ".cp-summary a[href=?]", @urls.last
    assert_select "p", /lead changed 2 times/
    assert_select ".cp-transition time[datetime=?]", "2026-10-12"
    assert_equal [@urls.first, @urls.last], css_select(".cp-transition a").map { |link| link["href"] }
    assert_match(/Guide took the lead from Servicing/, css_select(".cp-transition").text.squish)
    assert_select ".cp-periods dd", text: "9 clicks"
    assert_select ".cp-periods dd", text: "3 clicks"
    assert_select ".cp-outcome", text: "6 fewer clicks"
    assert_select ".cp-note", /Google showed your site 60 times in the first period and 85 in the second/
    assert_select ".cp-history tbody tr", count: 8
    assert_select ".cp-history time[datetime=?]", "2026-11-02"
    assert_select ".cp-history td a[href=?]", @urls.last
    assert_select ".cp-history td", text: "No clear lead"
    assert_select "form button[value=accepted_overlap]", text: "Keep both pages"
    assert_select "a[href=?]", keyword_path(@keyword, device: "desktop", anchor: "preferred-page")
  end

  test "manager decisions persist, can be reopened, and an outdated form cannot overwrite a fresh review" do
    @membership.update!(role: "manager")
    finding = record_finding
    get competing_page_path(finding)
    original_version = css_select("input[name=version]").first["value"]
    patch competing_page_path(finding), params: {version: original_version, disposition: "accepted_overlap"}
    assert_redirected_to competing_page_path(finding)
    follow_redirect!
    assert_select ".cp-decision strong", "Keeping both pages"
    patch competing_page_path(finding), params: {version: original_version, disposition: "open"}
    assert_response :conflict
    assert_equal "accepted_overlap", finding.reload.disposition
    get competing_pages_path
    assert_select "summary", /Your saved decisions/
    assert_select ".cp-verdict", /has a saved decision/
    latest_version = finding.updated_at.iso8601(6)
    patch competing_page_path(finding), params: {version: latest_version, disposition: "anything"}
    assert_response :unprocessable_entity
    patch competing_page_path(finding), params: {version: latest_version, disposition: "open"}
    assert_redirected_to competing_page_path(finding)
    assert_equal "open", finding.reload.disposition
    get competing_page_path(finding)
    version = css_select("input[name=version]").first["value"]
    finding.update!(evidence: finding.evidence.merge("switch_count" => 3))
    patch competing_page_path(finding), params: {version: version, disposition: "monitor"}
    assert_response :conflict
    assert_select "p", /lead changed 3 times/
    assert_equal "open", finding.reload.disposition
  end

  test "viewers can read but cannot change a decision and other sites and old markets cannot open the record" do
    finding = record_finding
    @membership.update!(role: "viewer")
    get competing_page_path(finding)
    assert_response :success
    assert_select ".cp-decision form", count: 0
    patch competing_page_path(finding), params: {version: finding.updated_at.iso8601(6), disposition: "monitor"}
    assert_response :forbidden
    @membership.update!(role: "owner")
    @site.update!(rank_country_code: "US")
    get competing_page_path(finding)
    assert_response :not_found
    @site.update!(rank_country_code: "GB")
    other = @site.workspace.sites.create!(name: "Other business", host: "other.example", location: "York")
    post select_site_path(other)
    get competing_page_path(finding)
    assert_response :not_found
    patch competing_page_path(finding), params: {version: finding.updated_at.iso8601(6), disposition: "monitor"}
    assert_response :not_found
    assert_equal "open", finding.reload.disposition
  end

  test "missing click data remains unknown and explicit zero remains visible" do
    finding = record_finding
    clicks = finding.evidence.fetch("clicks").merge("previous" => 0, "current" => nil, "change" => nil, "trend" => "unknown")
    finding.update!(evidence: finding.evidence.merge("clicks" => clicks))
    get competing_page_path(finding)
    assert_select ".cp-outcome", "Click trend unknown"
    assert_select ".cp-periods dd", text: "0 clicks"
    assert_select ".cp-periods dd", text: "Incomplete data"
  end

  test "empty views distinguish waiting for the first sync from a completed week without a pair or a disconnected site" do
    get competing_pages_path
    assert_select "h2", "Waiting for weekly search data"
    SearchConsolePageWeek.create!(site: @site, property: @property, country: "GBR", device: "desktop",
      week_start: Date.new(2026, 11, 16), query: @keyword.phrase, pages: [])
    @connection.update!(page_week_synced_at: Time.current)
    get competing_pages_path
    assert_select "h2", /No competing pair found/
    @connection.destroy!
    get competing_pages_path
    assert_select "a[href=?]", search_console_path, text: "View Search Console connection"
  end

  test "reconnection flags saved readings, a disconnected binding hides them and a deleted keyword cannot expose them" do
    finding = record_finding
    @connection.update!(status: "reconnect", page_week_synced_at: Time.current)
    get competing_pages_path
    assert_select ".cp-stale", /Updates are paused/
    assert_select ".cp-note", /Weeks through 22 Nov 2026.*Last checked/
    get competing_page_path(finding)
    assert_select ".cp-stale", /last saved/
    @connection.update!(status: "disconnected")
    get competing_page_path(finding)
    assert_response :not_found
    @connection.update!(status: "connected")
    @keyword.destroy!
    get competing_page_path(finding)
    assert_response :not_found
    get competing_pages_path
    assert_select "a.cp-keyword", count: 0
  end

  test "a single switch is a watch item and opens the exact page that gained the lead" do
    finding = record_finding(level: "watch")
    destination = "https://westbridge.example/services/laser-treatment-for-acne-scars/"
    pair = [@urls.first, destination]
    weeks = finding.evidence.fetch("weeks")
    weeks[1]["leader_url"] = weeks[2]["leader_url"] = destination
    finding.update!(evidence: finding.evidence.merge("weeks" => weeks, "pages" => pair, "switch_count" => 1, "recommended_page_url" => destination))
    get competing_pages_path(keyword_id: @keyword.id)
    assert_select ".cp-verdict", /No confirmed pattern/
    get competing_page_path(finding)
    assert_select ".cp-outcome", /lead changed once/
    assert_select ".cp-transition a[href=?]", destination, text: "Laser treatment for acne scars"
    assert_select ".cp-transition time[datetime=?]", "2026-10-05"
    assert_select ".cp-next a[href=?]", destination, text: "Open the page that took the lead"
    weeks[0]["leader_url"] = destination
    finding.update!(evidence: finding.evidence.merge("switch_count" => 0, "weeks" => weeks, "recommended_page_url" => "https://other.example/"))
    get competing_page_path(finding)
    assert_select ".cp-outcome", /No lead switch/
    assert_select ".cp-next a", text: "Open the page that took the lead", count: 0
  end

  test "address variants that share a page label show their full addresses" do
    finding = record_finding(level: "limited")
    variants = ["https://westbridge.example/", "https://www.westbridge.example/"]
    finding.update!(evidence: finding.evidence.merge("pages" => variants))
    get competing_page_path(finding)
    variants.each { |url| assert_select ".cp-page-list a[href=?]", url, text: url }
  end

  test "a gap or a close call separates leaders and the summary only dates a reported lead" do
    finding = record_finding(level: "watch")
    weeks = finding.evidence.fetch("weeks")
    weeks[1].merge!("leader_url" => nil, "state" => "tie")
    weeks[2]["leader_url"] = @urls.last
    finding.update!(evidence: finding.evidence.merge("weeks" => weeks, "switch_count" => 0))
    get competing_page_path(finding)
    assert_select ".cp-transition", count: 0
    assert_select ".cp-page-list li", text: /Servicing.*Led in the week beginning 12 Oct 2026/m
    assert_select ".cp-page-list li", text: /Guide.*Led/m, count: 0
    assert_select ".cp-history td", "Too close to call"

    weeks[7].merge!("state" => "leader", "leader_url" => "https://westbridge.example/unrelated/")
    finding.update!(evidence: finding.evidence.merge("weeks" => weeks))
    get competing_page_path(finding)
    assert_select ".cp-page-list .cp-note", count: 0
  end

  test "distinct paths whose readable names would collide remain visibly distinguishable" do
    finding = record_finding
    pair = %w[https://westbridge.example/repair/central-heating/ https://westbridge.example/install/central_heating/]
    weeks = finding.evidence.fetch("weeks")
    weeks[0]["leader_url"], weeks[1]["leader_url"], weeks[2]["leader_url"] = [pair.first, pair.last, pair.last]
    finding.update!(evidence: finding.evidence.merge("weeks" => weeks, "pages" => pair, "switch_count" => 1))
    get competing_page_path(finding)
    pair.each { |url| assert_select ".cp-transition a[href=?]", url, text: url }
  end

  test "one promptless request queues once and its saved recommendation belongs to the person who asked" do
    setting = enable_page_advice
    finding = record_finding
    SolidQueue::Process.insert_all!([{kind: "Worker", name: "page-advice-test", pid: 100,
      last_heartbeat_at: Time.current, created_at: 1.minute.ago}])
    path = recommendation_competing_page_path(finding)
    anchored = competing_page_path(finding, anchor: "ai-recommendation")
    version = finding.updated_at.iso8601(6)
    assert_no_enqueued_jobs do
      get competing_page_path(finding)
      assert_select "form[action=?] button", path, text: /Get AI recommendation/
    end
    assert_enqueued_jobs 1, only: AiRunJob do
      assert_difference("AiRun.count", 1) do
        2.times { post path, params: {version: version} }
      end
    end
    assert_redirected_to anchored
    follow_redirect!
    assert_select "[data-ai-pending]", /queued/
    run = AiRun.where(kind: "page_advice").sole
    evidence = CompetingPages::Advice.build(finding: finding, setting: setting)
    answer = CompetingPages::Advice.render({"decision_key" => "compare_purposes"}, evidence.fetch("facts"))
    run.update!(status: "complete", evidence: evidence, answer: answer, finished_at: Time.current)
    assert_no_enqueued_jobs do
      get anchored
      assert_response :success
      assert_select "#ai-recommendation .cp-advice-origin", /Searchdesk AI recommendation/
      assert_select "#ai-recommendation h2", "Leave the review open"
      assert_select "#ai-recommendation dt", "When to review"
      assert_select "#ai-recommendation a[href='#cp-weeks']"
      assert_select "#ai-recommendation form[action=?]", path, count: 0
      assert_includes response.headers["Cache-Control"], "no-store"
      assert_equal "open", finding.reload.disposition
    end
    get assistant_path
    assert_select "a[href=?]", assistant_run_path(run)
    get assistant_run_path(run)
    assert_redirected_to anchored

    manager = User.create!(email: "private-manager@example.test", password: "long-local-test-password")
    @site.workspace.memberships.create!(user: manager, role: "manager")
    post login_path, params: {session: {email: manager.email, password: "long-local-test-password"}}
    get competing_page_path(finding)
    assert_select ".cp-advice-origin", count: 0
    get assistant_run_path(run)
    assert_response :not_found
    post login_path, params: {session: {email: @membership.user.email, password: "long-local-test-password"}}
    delete assistant_run_path(run)
    assert_redirected_to anchored
    assert_empty run.reload.answer
  end

  test "an explicit request can finish a saved queued review locally with the worker offline" do
    enable_page_advice
    finding = record_finding(level: "limited")
    pending = AiRun.request_page_advice!(finding: finding, user: @membership.user)
    get competing_page_path(finding)
    assert_select "button", text: /Finish queued recommendation/
    assert pending.reload.status == "pending"
    assert_no_enqueued_jobs do
      assert_no_difference("AiRun.count") do
        2.times { post recommendation_competing_page_path(finding), params: {version: finding.updated_at.iso8601(6)} }
      end
    end
    follow_redirect!
    assert_response :success
    assert_equal ["fallback", "one_supported_choice", 0], pending.reload.attributes.values_at("status", "failure_code", "actual_microusd")
    assert_select ".cp-advice-origin", /saved SEO evidence/
    assert_select "#ai-recommendation", /used no AI credit/
    assert_select "button", text: /Retry AI recommendation/, count: 0
  end

  test "interrupted reservations cannot start a second paid attempt" do
    enable_page_advice
    finding = record_finding
    run = AiRun.request_page_advice!(finding: finding, user: @membership.user)
    run.update!(status: "running", attempted_at: 11.minutes.ago, reserved_microusd: 1000)
    get competing_page_path(finding)
    assert_select "button", "Check interrupted request"
    assert_equal "running", run.reload.status
    assert_no_enqueued_jobs do
      assert_no_difference("AiRun.count") do
        post recommendation_competing_page_path(finding), params: {version: finding.updated_at.iso8601(6)}
      end
    end
    follow_redirect!
    assert_select "#ai-recommendation", /estimated charge remains reserved/
    assert_select "button", text: /Retry AI recommendation/, count: 0
    assert_equal ["failed", "uncertain", nil], run.reload.attributes.values_at("status", "failure_code", "actual_microusd")
  end

  test "a rejected AI choice explains the local result and only offers a paid retry when usage is known" do
    setting = enable_page_advice
    finding = record_finding
    run = AiRun.request_page_advice!(finding: finding, user: @membership.user)
    evidence = CompetingPages::Advice.build(finding: finding, setting: setting)
    run.update!(status: "fallback", failure_code: "invalid_response", attempted_at: Time.current, finished_at: Time.current,
      actual_microusd: 25, reserved_microusd: 1000, evidence: evidence, answer: CompetingPages::Advice.fallback(evidence.fetch("facts")))
    get competing_page_path(finding)
    assert_select ".cp-advice-origin", /saved SEO evidence/
    assert_select "#ai-recommendation [role=status]", /OpenAI did not return a usable decision/
    assert_select "button", text: /Try AI again/
    assert_select "input[name=retry_run_id][value=?]", run.id.to_s
    assert_select ".cp-advice-request", /new request.*previous usage stays recorded/
    run.update!(actual_microusd: nil)
    get competing_page_path(finding)
    assert_select "#ai-recommendation [role=status]", /cost of that request is unknown/
    assert_select "button", text: /Try AI again/, count: 0
    assert_select "input[name=retry_run_id]", count: 0
  end

  test "new AI requests respect the reviewed snapshot, Google sharing and site membership" do
    setting = enable_page_advice
    finding = record_finding
    path = recommendation_competing_page_path(finding)
    @membership.update!(role: "viewer")
    get competing_page_path(finding)
    assert_select "form[action=?]", path, count: 0
    post path, params: {version: finding.updated_at.iso8601(6)}
    assert_response :forbidden
    @membership.update!(role: "owner")
    assert_no_difference("AiRun.count") do
      post path, params: {version: "earlier"}
      assert_response :conflict
      assert_select ".flash", /review has changed/
      setting.update!(share_google: false)
      get competing_page_path(finding)
      assert_select "#ai-recommendation a[href=?]", assistant_settings_path
      assert_select "form[action=?]", path, count: 0
      post path, params: {version: finding.updated_at.iso8601(6)}
      assert_redirected_to competing_page_path(finding, anchor: "ai-recommendation")
      other = @site.workspace.sites.create!(name: "Other site", host: "other.example", location: "York")
      post select_site_path(other)
      post path, params: {version: finding.updated_at.iso8601(6)}
      assert_response :not_found
    end
  end

  test "owner checks a result without AI and returns to the exact listing and the developer handoff" do
    finding = record_finding
    path = listing_check_competing_page_path(finding, keyword_id: @keyword.id)
    with_listing_checker do |calls, receipt|
      get competing_page_path(finding, keyword_id: @keyword.id)
      assert_select "#ai-recommendation a[href='#listing-check']"
      assert_select "#listing-check form[action=?]", path
      assert_select "#listing-check button", "Check Google result"
      assert_empty calls
      version = css_select("#listing-check input[name=version]").first["value"]
      post path, params: {version: version, target_url: "https://elsewhere.example/"}
      assert_redirected_to competing_page_path(finding, keyword_id: @keyword.id, anchor: "listing-check")
      follow_redirect!
      assert_response :success
      assert_equal [[finding.id, version]], calls
      assert_select "#listing-check h3", "Google search result"
      assert_select "#listing-check dd", "Clinic & consultations"
      assert_select "#listing-check dd", "A short <mobile> snippet…"
      assert_select "#listing-check mobile", count: 0
      assert_select "#listing-check dd", "Consultations in York"
      assert_select "#listing-check dt", "Suggested title"
      assert_select "#listing-check dt", "Keep this description"
      assert_select "#listing-check p", /The title differs. The description matches./
      assert_select "#listing-check time", count: 2
      assert_select "#listing-check .cp-note", /Desktop · York · English/
      assert_select "#listing-check textarea[readonly]", receipt.dig("draft", "instructions")
      assert_select "#listing-check [data-copy-handoff]"
      assert_select "#listing-check button", "Check again"
      assert_no_difference("AiRun.count") { get competing_page_path(finding) }
      assert_equal 1, calls.length
    end
  end

  test "a different local result remains separate from the homepage and viewers can only read" do
    finding = record_finding
    with_listing_checker do |calls, receipt|
      google = receipt.fetch("google")
      google.merge!("status" => "target_not_seen", "coverage" => 28, "depth" => 30,
        "other_result" => {"url" => @urls.first, "title" => "Our guide", "description" => nil, "position" => 19})
      @membership.update!(role: "manager")
      post listing_check_competing_page_path(finding), params: {version: finding.updated_at.iso8601(6)}
      assert_response :see_other
      @membership.update!(role: "viewer")
      get competing_page_path(finding)
      assert_response :success
      assert_select "#listing-check h3", "Another page Google showed from your site"
      assert_select "#listing-check a[href=?]", @urls.first
      assert_select "#listing-check", /Position 19/
      assert_select "#listing-check", /positions 1–28 of 30 requested/
      assert_select "#listing-check dd", "Snippet unavailable in this capture."
      assert_select "#listing-check p", /No homepage snippet to compare in this capture/
      assert_select "#listing-check", text: /The title differs/, count: 0
      assert_select "#listing-check form", count: 0
      post listing_check_competing_page_path(finding), params: {version: finding.updated_at.iso8601(6)}
      assert_response :forbidden
      assert_equal 1, calls.length
    end
  end

  test "stale reviews, old markets, a different site and disconnected sources cannot start a listing check" do
    finding = record_finding
    path = listing_check_competing_page_path(finding)
    version = finding.updated_at.iso8601(6)
    with_listing_checker do |calls, _|
      post path, params: {version: "old"}
      assert_response :conflict
      assert_select ".flash", /review has changed/
      @connection.update!(status: "reconnect")
      get competing_page_path(finding)
      assert_select "#listing-check", count: 0
      post path, params: {version: version}
      assert_response :not_found
      @connection.update!(status: "connected")
      @site.update!(rank_country_code: "US")
      post path, params: {version: version}
      assert_response :not_found
      @site.update!(rank_country_code: "GB")
      other = @site.workspace.sites.create!(name: "Other site", host: "other.example", location: "York")
      post select_site_path(other)
      post path, params: {version: version}
      assert_response :not_found
      assert_empty calls
    end
  end

  test "missing snippets and ambiguous page descriptions leave the comparison incomplete" do
    finding = record_finding
    with_listing_checker do |_calls, receipt|
      receipt.fetch("google")["description"] = nil
      receipt.fetch("page").merge!("field_states" => {"description" => "multiple"}, "description" => nil)
      receipt.fetch("comparison")["description"] = "not_comparable"
      receipt["draft"] = {"status" => "unavailable", "reason" => "Review the duplicate descriptions."}
      post listing_check_competing_page_path(finding), params: {version: finding.updated_at.iso8601(6)}
      follow_redirect!
      assert_select "#listing-check dd", "Snippet unavailable in this capture."
      assert_select "#listing-check dd", "The page contains multiple description tags."
      assert_select "#listing-check p", /enough text to compare the description/
      assert_select "#listing-check h3", "Next step"
      assert_select "#listing-check p", /Review the duplicate descriptions/
      assert_select "#listing-check [data-copy-handoff]", count: 0
    end
  end

  test "the ranking page review follows the captured result, separates a redirect and shows exact developer instructions" do
    finding = record_finding
    with_article_checker(finding) do |calls, receipt|
      path = article_check_competing_page_path(finding, keyword_id: @keyword.id)
      get competing_page_path(finding, keyword_id: @keyword.id)
      assert_select "#listing-google"
      assert_select "#listing-check form[action=?] button", path, "Check this ranking page"
      assert_select "#listing-check input[name=capture_key][value='saved-capture']"
      assert_select "#ranking-article", count: 0
      assert_empty calls
      version = finding.updated_at.iso8601(6)
      post path, params: {version: version, capture_key: "saved-capture", url: "https://unrelated.example/", homepage_url: "https://unrelated.example/"}
      assert_redirected_to competing_page_path(finding, keyword_id: @keyword.id, anchor: "ranking-article")
      follow_redirect!
      assert_response :success
      assert_equal [[finding.id, version, "saved-capture"]], calls
      assert_select "#listing-check a[href='#ranking-article']"
      assert_select "#listing-check textarea#listing-handoff"
      assert_select "#ranking-article h2", "Review of the page Google ranked"
      assert_select "#ranking-article .cp-verdict strong", "Keep the existing redirect"
      assert_select "#ranking-article p", /no current article title or description/
      assert_select "#ranking-article strong", "HTTP 301"
      assert_select "#ranking-article a[href=?]", @urls.last
      assert_select "#ranking-article strong", "Destination page wording"
      assert_select "#ranking-article dd", "Booking a service in York"
      assert_select "#ranking-article .cp-article-archive time[datetime^='2026-11-01']"
      assert_select "#ranking-article .cp-article-archive", /before Google showed the old address/
      assert_select "#ranking-article .cp-article-archive a[href=?]", source_snapshot_path(12)
      assert_select "#ranking-article .cp-article-archive", /visible words in Google’s snippet also appear/
      assert_select "#ranking-article .cp-article-archive dd", "A saved <description>"
      assert_select "#ranking-article description", count: 0
      assert_select "#ranking-article .cp-article-edits strong", "Optional destination meta description"
      assert_select "#ranking-article .cp-article-edits details p", "Prior description"
      assert_select "#ranking-article textarea#ranking-article-handoff", receipt.dig("draft", "instructions")
      assert_select "#ranking-article button[data-copy-handoff]", "Copy ranking page instructions"
      @membership.update!(role: "viewer")
      get competing_page_path(finding)
      assert_select "#ranking-article"
      assert_select "#ranking-article form", count: 0
      post path, params: {version: version, capture_key: "saved-capture"}
      assert_response :forbidden
      assert_equal 1, calls.size
    end
  end

  test "a readable ranking article compares each field and shows the verified homepage link" do
    finding = record_finding
    with_article_checker(finding) do |_calls, receipt|
      @membership.update!(role: "manager")
      receipt.delete("archive")
      receipt["page"] = {"status" => "observed", "url" => @urls.first, "checked_at" => receipt["checked_at"],
        "title" => "How to book a service", "description" => "Check your model before booking."}
      receipt["comparison"] = {"title" => "truncated", "description" => "different"}
      receipt["link"] = {"outcome" => "contextual", "anchor" => "Book a visit", "section" => "Next steps", "placement" => "Article text"}
      receipt["draft"].merge!("decision" => "Improve the article", "link_instruction" => "Keep the existing booking link.", "edits" => [])
      post article_check_competing_page_path(finding), params: {version: finding.updated_at.iso8601(6), capture_key: "saved-capture"}
      follow_redirect!
      assert_select "#ranking-article", /The captured title matches the start/
      assert_select "#ranking-article", /The description differs/
      assert_select "#ranking-article", /Book a visit.*Next steps/
      assert_select "#article-archive", count: 0
      assert_select "#ranking-article h3", text: "Exact edits", count: 0
    end
  end

  test "stale captures and out-of-scope records cannot run a ranking page check" do
    finding = record_finding
    path = article_check_competing_page_path(finding)
    version = finding.updated_at.iso8601(6)
    with_article_checker(finding) do |calls, _receipt|
      post path, params: {version: version, capture_key: "from-another-result"}
      assert_response :conflict
      assert_select "#ranking-article", count: 0
      @connection.update!(status: "reconnect")
      post path, params: {version: version, capture_key: "saved-capture"}
      assert_response :not_found
      @connection.update!(status: "connected")
      other = @site.workspace.sites.create!(name: "Other site", host: "other.example", location: "York")
      post select_site_path(other)
      post path, params: {version: version, capture_key: "saved-capture"}
      assert_response :not_found
      assert_empty calls
    end
  end

  private

  def with_article_checker(finding)
    with_listing_checker do |_, listing|
      article_url, destination_url = @urls
      matched = {"url" => article_url, "title" => "How to book…", "description" => "Plan your visit.", "position" => 19}
      google = listing.fetch("google")
      google.merge!("status" => "target_not_seen", "other_result" => matched)
      post listing_check_competing_page_path(finding), params: {version: finding.updated_at.iso8601(6)}
      report = {"checked_at" => "2026-11-26T09:00:00Z", "target_url" => article_url, "homepage_url" => listing["target_url"],
        "google" => google.except("other_result").merge(matched, "status" => "observed"),
        "page" => {"status" => "redirected", "url" => article_url,
          "redirects" => [{"url" => article_url, "status" => 301, "location" => destination_url}],
          "destination" => {"status" => "observed", "url" => destination_url, "title" => "Booking a service in York", "description" => "Prior description"}},
        "archive" => {"captured_at" => "2026-11-01T09:00:00Z", "title" => "How to book a service", "description" => "A saved <description>",
          "snapshot_id" => 12, "prior_redirect" => {"status" => 301, "location" => destination_url, "captured_at" => "2026-11-02T13:00:00Z"},
          "comparison" => {"title" => "truncated", "description" => "different"}, "snippet_in_body" => true, "matched_passage" => "Plan your visit."},
        "comparison" => {"title" => "not_comparable", "description" => "not_comparable"}, "link" => {"outcome" => "source_redirected"},
        "draft" => {"decision" => "Keep the existing redirect", "reason" => "Visitors now reach the service page.",
          "edits" => [{"label" => "Optional destination meta description", "before" => "Prior description", "after" => "Read about the service."}],
          "link_instruction" => "The old address redirects before an article can load.", "instructions" => "Keep the verified redirect."}}
      calls = []
      stale = CompetingPages::ListingCheck::Stale
      checker = Class.new
      checker.const_set(:Stale, stale)
      checker.const_set(:Busy, CompetingPages::ListingCheck::Busy)
      checker.define_singleton_method(:candidate) { |_| matched.merge("capture_key" => "saved-capture") }
      checker.define_singleton_method(:saved) { |_| report if calls.any? }
      checker.define_singleton_method(:call) do |finding:, version:, capture_key:|
        raise stale unless capture_key == "saved-capture" && version == finding.updated_at.iso8601(6)
        calls << [finding.id, version, capture_key]
        report
      end
      stub_const(CompetingPages, :ArticleCheck, checker) { yield calls, report }
    end
  end

  def with_listing_checker
    target = "https://westbridge.example/"
    excerpt = "A short <mobile> snippet…"
    receipt = {
      "target_url" => target,
      "google" => {"status" => "observed", "url" => target, "title" => "Clinic & consultations", "description" => excerpt,
        "device" => "desktop", "location" => "York", "language" => "en", "position" => 5, "captured_at" => "2026-11-24T08:00:00Z"},
      "page" => {"status" => "observed", "url" => target, "title" => "Consultations in York", "description" => excerpt,
        "checked_at" => "2026-11-26T14:05:00Z"},
      "comparison" => {"title" => "different", "description" => "matches"},
      "draft" => {"status" => "proposed", "reason" => "Mention the clinic’s location.", "title" => "York consultations",
        "description" => excerpt, "instructions" => "Set the title to York consultations. Then verify the public page."}
    }
    calls = []
    checker = Class.new
    stale_error = CompetingPages::ListingCheck::Stale
    checker.const_set(:Stale, stale_error)
    checker.const_set(:Busy, CompetingPages::ListingCheck::Busy)
    checker.define_singleton_method(:target_for) { |_finding| target }
    checker.define_singleton_method(:saved) { |finding| receipt if calls.any? { |id, _| id == finding.id } }
    checker.define_singleton_method(:call) do |finding:, version:|
      raise stale_error unless version == finding.updated_at.iso8601(6)
      calls << [finding.id, version]
      receipt
    end
    stub_const(CompetingPages, :ListingCheck, checker) { yield calls, receipt }
  end

  def enable_page_advice
    @connection.update!(refresh_token: "weekly-search-fixture")
    account = @site.workspace.create_ai_connection!(api_key: "sk-offline-fixture", monthly_budget_cents: 100)
    account.update!(status: "ready")
    @site.create_ai_setting!(enabled: true, share_google: true, managers_enabled: true)
  end

  def record_finding(query: @keyword, level: "review")
    start = Date.new(2026, 9, 28)
    weeks = Array.new(8) do |i|
      url = [@urls.first, @urls.last, @urls.first][i]
      {"week_start" => (start + i * 7).iso8601, "leader_url" => url, "state" => url ? "leader" : "sparse", "pages" => []}
    end
    clicks = {"previous" => 9, "current" => 3, "trend" => "down", "change" => -6, "previous_impressions" => 60, "current_impressions" => 85,
      "previous_start" => start.iso8601, "previous_end" => (start + 27).iso8601,
      "current_start" => (start + 28).iso8601, "current_end" => (start + 55).iso8601}
    SiteFinding.create!(site: @site, keyword: query, fingerprint: SecureRandom.hex(32), kind: "competing_pages", level: level,
      evidence: {"query" => query.phrase, "device" => "desktop", "country" => "GBR", "property" => @property,
        "pages" => @urls, "clicks" => clicks, "weeks" => weeks, "switch_count" => 2, "recommendation" => "Review both pages first."})
  end
end
