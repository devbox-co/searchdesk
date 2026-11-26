require "test_helper"

class AssistantInterfaceTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  setup do
    @workspace = Workspace.create!(name: "Assistant workspace")
    @site = @workspace.sites.create!(name: "Example Clinic", host: "clinic.example", location: "Norwich")
    @owner = member("owner")
    @manager = member("manager")
    @viewer = member("viewer")
    sign_in(@owner)
  end

  test "owner can connect, test, preview and opt into the daily brief separately" do
    get integrations_path(q: "ChatGPT")
    assert_select ".integration-service a[href=?]", integration_path("openai")
    get integration_path("openai")
    assert_select "a[href=?]", assistant_settings_path
    get assistant_settings_path
    assert_select "input[type=password][name=?]", "ai_connection[api_key]"
    assert_select "input[name=?][value='0.00']", "ai_connection[monthly_budget_usd]"
    save_connection
    connection = AiConnection.find_by!(workspace: @workspace)
    assert_equal 100, connection.monthly_budget_cents
    assert_equal "untested", connection.status
    assert_nil AiSetting.find_by(site: @site)
    get assistant_settings_path(preview: "1")
    assert_response :success
    assert_select ".ai-preview li", minimum: 1
    assert_not_includes response.body, "sk-proj-test-account"
    test_key = css_select(%(form[action="#{test_assistant_connection_path}"] input[name=request_key])).first["value"]
    assert_enqueued_jobs 1, only: AiRunJob do
      post test_assistant_connection_path, params: {request_key: test_key}
    end
    test_run = AiRun.find_by!(kind: "test", site: @site)
    assert_redirected_to assistant_run_path(test_run)
    follow_redirect!
    assert_select "[data-ai-pending]"
    patch assistant_site_settings_path, params: {ai_setting: {enabled: "1", daily_brief_enabled: "1", priorities: "Improve local visibility"}}
    assert_redirected_to assistant_settings_path(anchor: "site-settings")
    setting = AiSetting.find_by!(site: @site)
    assert setting.daily_brief_enabled?
    assert_not setting.share_google?
    get assistant_path
    assert_select "form[action=?]", assistant_questions_path, count: 0
    connection.update!(status: "ready", last_verified_at: Time.current)
    get assistant_path(starter: "movement")
    assert_select "textarea[name=question]", text: /changed since tracking began/
    delete assistant_connection_path
    assert_not connection.reload.configured?
    assert_not setting.reload.daily_brief_enabled?
    get assistant_settings_path
    assert_not_includes response.body, "sk-proj-test-account"
  end

  test "site-scoped questions are private, duplicate forms share a receipt and viewers can read the published brief" do
    save_connection
    AiConnection.find_by!(workspace: @workspace).update!(status: "ready")
    setting = AiSetting.create!(site: @site, enabled: true, managers_enabled: true, daily_brief_enabled: true)
    sign_in(@manager)
    get assistant_path
    key = css_select("input[name=request_key]").first["value"]
    assert_enqueued_jobs 1, only: AiRunJob do
      assert_difference("AiRun.count", 1) do
        2.times { post assistant_questions_path, params: {question: "Which keyword moved?", request_key: key} }
      end
    end
    question = AiRun.find_by!(kind: "question", site: @site)
    assert_equal @manager.id, question.user_id
    complete(question, setting)
    get assistant_run_path(question)
    assert_response :success
    assert_select ".ai-citations a[href^='/rankings']"
    post assistant_questions_path, params: {question: "What about mobile?", request_key: SecureRandom.uuid, parent_id: question.id}
    assert_equal question.id, AiRun.find_by!(question: "What about mobile?").parent_id
    brief = AiRun.request!(site: @site, user: nil, kind: "brief", report_on: Date.current)
    complete(brief, setting)
    sign_in(@viewer)
    get assistant_run_path(brief)
    assert_response :success
    assert_select ".brief-report-header .brief-origin", "Prepared by Searchdesk AI"
    assert_select ".brief-measurements:not([open]) .brief-sources a[href^='/rankings']"
    assert_select "form[action=?]", assistant_questions_path, count: 0
    get assistant_run_path(question)
    assert_response :not_found
    get assistant_path
    assert_select "a[href=?]", assistant_run_path(brief)
    assert_not_includes response.body, "Which keyword moved?"
    get dashboard_path
    assert_select ".overview-brief .brief-origin", "Prepared by Searchdesk AI"
    sign_in(@owner)
    get assistant_run_path(question)
    assert_response :not_found
    delete assistant_history_path
    assert_redirected_to assistant_path
    assert_empty question.reload.evidence
    assert_empty brief.reload.answer
  end

  test "managers cannot manage credentials, share sources or select a parent from a different site" do
    save_connection
    AiConnection.find_by!(workspace: @workspace).update!(status: "ready")
    AiSetting.create!(site: @site, enabled: true, managers_enabled: false)
    sign_in(@manager)
    get assistant_settings_path
    assert_response :forbidden
    patch assistant_connection_path, params: {ai_connection: {monthly_budget_usd: 100}}
    assert_response :forbidden
    patch assistant_site_settings_path, params: {ai_setting: {managers_enabled: "1", share_google: "1"}}
    assert_response :forbidden
    assert_no_difference("AiRun.count") do
      post assistant_questions_path, params: {question: "Show rankings", request_key: SecureRandom.uuid}
      assert_response :forbidden
    end
    other = @workspace.sites.create!(name: "Other", host: "other.example", location: "Leeds")
    AiSetting.create!(site: other, enabled: true)
    other_run = AiRun.request!(site: other, user: @owner, kind: "question", question: "Other site's keywords?")
    sign_in(@owner)
    assert_no_difference("AiRun.count") do
      post assistant_questions_path, params: {question: "Tell me more?", parent_id: other_run.id, request_key: SecureRandom.uuid}
      assert_response :not_found
    end
  end

  test "only owners see an unpublished budget stop for today and its remedy" do
    save_connection
    AiConnection.find_by!(workspace: @workspace).update!(status: "ready")
    AiSetting.create!(site: @site, enabled: true, daily_brief_enabled: true)
    brief = AiRun.request!(site: @site, user: nil, kind: "brief")
    brief.update!(status: "budget", failure_code: "monthly_limit")
    get assistant_path
    assert_select "a[href=?]", assistant_run_path(brief), text: "View brief status"
    assert_select "p", text: /would exceed the workspace allowance/
    sign_in(@viewer)
    get assistant_path
    assert_select "a[href=?]", assistant_run_path(brief), count: 0
    get assistant_run_path(brief)
    assert_response :not_found
  end

  test "overview shows the latest published brief the selected site's viewer can still read" do
    save_connection
    AiConnection.find_by!(workspace: @workspace).update!(status: "ready")
    setting = @site.create_ai_setting!(enabled: true, daily_brief_enabled: true)
    older = AiRun.request!(site: @site, user: nil, kind: "brief", report_on: Date.current - 3)
    latest = AiRun.request!(site: @site, user: nil, kind: "brief", report_on: Date.current - 2)
    withdrawn = AiRun.request!(site: @site, user: nil, kind: "brief", report_on: Date.current - 1)
    pending = AiRun.request!(site: @site, user: nil, kind: "brief", report_on: Date.current)
    [older, latest, withdrawn].each { |run| complete(run, setting) }
    latest.update!(status: "fallback", answer: {"findings" => [{"text" => "Check the tracked treatment page.", "fact_ids" => []}]})
    withdrawn.update!(evidence: withdrawn.evidence.deep_merge("access" => {"sources" => ["google"]}))
    other = @workspace.sites.create!(name: "Other clinic", host: "other.example", location: "Leeds")

    sign_in(@viewer)
    get dashboard_path
    assert_response :success
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    assert_select ".overview-brief", count: 1 do
      assert_select "h2", "Latest daily SEO brief"
      assert_select "time[datetime=?]", latest.report_on.iso8601
      assert_select ".brief-origin", "Built from local evidence"
      assert_select ".brief-origin", text: "Prepared by Searchdesk AI", count: 0
      assert_select ".overview-brief-finding", "Check the tracked treatment page."
      assert_select "a[href=?]", assistant_run_path(latest), text: "Read full brief"
    end
    [older, withdrawn, pending].each { |run| assert_select ".overview-brief a[href=?]", assistant_run_path(run), count: 0 }
    get assistant_run_path(latest)
    assert_response :success
    assert_select ".brief-report-header .brief-origin", "Built from local evidence"
    assert_select ".brief-meaning", "Check the tracked treatment page."

    post select_site_path(other)
    get dashboard_path
    assert_response :success
    assert_select ".overview-brief", count: 0
    get assistant_run_path(latest)
    assert_response :not_found
  end

  test "brief and overview show the takeaway and first action before the raw measurements" do
    save_connection
    AiConnection.find_by!(workspace: @workspace).update!(status: "ready")
    setting = @site.create_ai_setting!(enabled: true, daily_brief_enabled: true)
    brief = AiRun.request!(site: @site, user: nil, kind: "brief")
    evidence = AiAssistant::Evidence.build(site: @site, setting: setting, kind: "brief", day: brief.report_on, question: "")
    numbers = "On 2026-11-25 in Norwich,England,United Kingdom, Google organic tracking on desktop and mobile " \
      "covered 14 keyword-device checks across 7 keywords. 7 numeric positions, 0 verified outside the top 30, " \
      "7 incomplete. 7 usable baselines. 1 unchanged, 4 down, 2 up. Incomplete checks reached 20–29 of the first 30 positions."
    evidence["facts"] = [{"id" => "F1", "text" => numbers, "source" => "Manual import", "url" => rankings_path}]
    brief.update!(status: "complete", evidence: evidence, answer: {"findings" => [{"text" => numbers, "fact_ids" => ["F1"]}]})

    assert_no_enqueued_jobs do
      get assistant_run_path(brief)
      assert_response :success
      assert_select ".brief-first-action h2", "Do this first"
      first_action = css_select(".brief-first-action p").first.text
      assert first_action.present?
      assert_select ".brief-measurements:not([open]) .brief-sources p", numbers
      assert_select ".brief-measurements a[href=?]", rankings_path, text: "Manual import"
      headline = css_select(".ai-findings > li > h3").first.text
      meaning = css_select(".ai-findings > li > .brief-meaning").first.text
      assert headline.present?
      assert meaning.present?
      refute_match(/keyword-device|England,United Kingdom|2026-11-25/, [headline, meaning, first_action].join(" "))

      get dashboard_path
      assert_response :success
      assert_select ".overview-brief h3", headline
      assert_select ".overview-brief-finding", meaning
      assert_select ".overview-brief-finding", text: /#{Regexp.escape(first_action)}/
      assert_select ".overview-brief", text: /keyword-device checks/, count: 0
    end
  end

  test "the local review shows a saved action with its evidence before OpenAI is connected" do
    travel_to Time.current.in_time_zone(@site.time_zone).noon
    record_page_mismatch
    assert_no_difference(["AiRun.count", "AiSetting.count"]) do
      assert_no_enqueued_jobs do
        get assistant_path
        assert_response :success
        assert_select ".ai-guided-review li:first-child", text: /clinic appointments/
        assert_select ".ai-guided-review a[href^='/actions?']", text: /Keyword actions/
        assert_select "form[action=?]", assistant_questions_path, count: 0
      end
    end

    other = @workspace.sites.create!(name: "Other", host: "other.example", location: "Leeds")
    Tracking::Enrollment.call(site: other, phrase: "new keyword", devices: ["mobile"])
    post select_site_path(other)
    get assistant_path
    assert_select ".ai-guided-review p", text: /Your review will appear/
    assert_select ".ai-guided-review a[href=?]", rankings_path
    assert_select ".ai-review-list li", count: 0
    assert_not_includes response.body, "clinic appointments"
  end

  test "one click uses the server question and the same receipt on retry" do
    travel_to Time.current.in_time_zone(@site.time_zone).noon
    record_page_mismatch
    save_connection
    AiConnection.find_by!(workspace: @workspace).update!(status: "ready")
    @site.create_ai_setting!(enabled: true)
    book = AiAssistant::Playbooks.find("priority")
    assert_no_enqueued_jobs do
      get assistant_path
      assert_select ".ai-guided-questions button", text: book.question
      assert_select ".ai-guided-questions input[name=playbook][value=maps]", count: 0
    end
    form = css_select(".ai-guided-questions form").find { |node| node.at_css("input[name=playbook]")["value"] == book.key }
    key = form.at_css("input[name=request_key]")["value"]
    assert_enqueued_jobs 1, only: AiRunJob do
      assert_difference("AiRun.count", 1) do
        2.times { post assistant_questions_path, params: {playbook: book.key, request_key: key, question: "Forged custom text"} }
      end
    end
    question = AiRun.find_by!(site: @site, kind: "question", question: book.question)
    assert_redirected_to assistant_run_path(question)
    assert_nil question.parent_id
    assert_equal @owner, question.user
    assert_no_difference("AiRun.count") do
      %w[maps unknown].each do |key|
        post assistant_questions_path, params: {playbook: key, request_key: SecureRandom.uuid}
        assert_response :unprocessable_entity
      end
      post assistant_questions_path, params: {playbook: book.key, request_key: "-" * 36}
      assert_response :unprocessable_entity
      sign_in(@viewer)
      post assistant_questions_path, params: {playbook: book.key, request_key: SecureRandom.uuid}
      assert_response :forbidden
    end
  end

  test "only a cited investigation can be continued from a past report, on its reporting date" do
    travel_to Time.current.in_time_zone(@site.time_zone).noon
    record_page_mismatch
    save_connection
    AiConnection.find_by!(workspace: @workspace).update!(status: "ready")
    setting = @site.create_ai_setting!(enabled: true, daily_brief_enabled: true)
    brief = AiRun.request!(site: @site, user: nil, kind: "brief")
    book = AiAssistant::Playbooks.find("priority")
    evidence = AiAssistant::Evidence.build(site: @site, setting: setting, kind: "brief", day: brief.report_on, question: "")
    cited = evidence.fetch("facts").find { |fact| book.matches?(fact) }
    brief.update!(status: "complete", evidence: evidence, answer: {"findings" => [{"text" => cited.fetch("text"), "fact_ids" => [cited.fetch("id")]}]})
    travel 1.day
    get assistant_run_path(brief)
    assert_response :success
    assert_select ".ai-guided-questions button", count: 1, text: book.question
    assert_select ".ai-guided-questions input[name=parent_id][value=?]", brief.id.to_s
    assert_no_difference("AiRun.count") do
      post assistant_questions_path, params: {playbook: "movement", parent_id: brief.id, request_key: SecureRandom.uuid}
      assert_response :unprocessable_entity
    end
    post assistant_questions_path, params: {playbook: book.key, parent_id: brief.id, request_key: SecureRandom.uuid}
    child = AiRun.find_by!(parent: brief, question: book.question)
    assert_equal brief.report_on, child.report_on
    assert_redirected_to assistant_run_path(child)
  end

  private

  def record_page_mismatch
    keyword = Tracking::Enrollment.call(site: @site, phrase: "clinic appointments",
      preferred_url: "https://clinic.example/appointments", devices: ["mobile"])
    series = keyword.tracking_series.current.sole
    items = (1..30).map do |rank|
      {"type" => "organic", "rank_group" => rank, "url" => rank == 3 ? "https://clinic.example/other" : "https://result-#{rank}.example/"}
    end
    Tracking::ManualImport.call(series: series, payload: series.settings.merge("captured_at" => Time.current.iso8601, "items" => items))
  end

  def complete(run, setting)
    evidence = AiAssistant::Evidence.build(site: @site, setting: setting, kind: run.kind, question: run.question, day: run.report_on)
    run.update!(status: "complete", evidence: evidence, answer: AiAssistant::Recipe.fallback(evidence.fetch("facts")))
  end

  def password
    "local-test-password"
  end

  def member(role)
    user = User.create!(email: "assistant-#{role}@example.test", password: password)
    @workspace.memberships.create!(user: user, role: role)
    user
  end

  def sign_in(user)
    delete logout_path
    post login_path, params: {session: {email: user.email, password: password}}
  end

  def save_connection
    patch assistant_connection_path, params: {ai_connection: {project_label: "Clinic automation", api_key: "sk-proj-test-account", monthly_budget_usd: "1.00"}}
    assert_redirected_to assistant_settings_path
  end
end
