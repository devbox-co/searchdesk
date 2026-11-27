require "test_helper"

class CompetingPageAdviceRunTest < ActiveJob::TestCase
  setup do
    travel_to Time.utc(2026, 11, 26, 12)
    @workspace = Workspace.create!(name: "York")
    @site = @workspace.sites.create!(name: "Town Heating", host: "heating.example", location: "York",
      tracking_mode: "manual", rank_country_code: "GB")
    @owner = User.create!(email: "heating@example.test", password: "a-long-fixture-password")
    @workspace.memberships.create!(user: @owner, role: "owner")
    @connection = @workspace.create_ai_connection!(api_key: "sk-test-fixture", monthly_budget_cents: 100, status: "ready")
    @setting = @site.create_ai_setting!(enabled: true, share_google: true)
    @gsc = @site.create_search_console_connection!(property: "sc-domain:heating.example", refresh_token: "fixture-grant",
      status: "connected", data_through: Date.new(2026, 11, 23))
    keyword = @site.keywords.create!(phrase: "boiler repair")
    urls = %w[https://heating.example/repair https://heating.example/guide]
    8.times do |i|
      pages = urls.map.with_index do |url, j|
        {"url" => url, "impressions" => j == (i < 7 ? 0 : 1) ? 25 : 5, "clicks" => 0, "position" => 3}
      end
      SearchConsolePageWeek.create!(site: @site, property: @gsc.property, country: "GBR", query: keyword.phrase,
        device: "desktop", week_start: Date.new(2026, 9, 28) + 7 * i, pages:, clicks: i < 4 ? 3 : 1, impressions: 28)
    end
    CompetingPages::Evaluator.call(site: @site, property: @gsc.property, country: "GBR")
    @finding = SiteFinding.competing_pages.current.where(site: @site).sole
    @job = AiRunJob.new
    @requests = []
    requests = @requests
    adapter = Object.new
    adapter.define_singleton_method(:call) do |api_key:, payload:|
      raise "Unexpected project" unless api_key == "sk-test-fixture"
      requests << payload
      AiAssistant::OpenaiClient::Response.new({"decision_key" => "check_new_leader"},
        100, 12, 16, "req_fixture")
    end
    @job.define_singleton_method(:provider) { adapter }
  end

  def request(**options)
    AiRun.request_page_advice!(finding: @finding, user: @owner, **options)
  end

  def current
    AiRun.current_page_advice(finding: @finding, user: @owner)
  end

  test "matching evidence reuses a private run and dispatches at most once; owner decisions do not invalidate it" do
    run = request
    assert run.previously_new_record?
    repeat = request
    refute repeat.previously_new_record?
    assert_equal run.id, repeat.id
    2.times { @job.perform(run.id) }
    assert_equal 1, @requests.size
    assert_equal ["complete", "check_new_leader", 16], [run.reload.status, run.answer["decision_key"], run.actual_microusd]
    assert_equal CompetingPages::Advice::VERSION, run.evidence.dig("receipt", "playbooks", "version")
    @finding.update!(disposition: "monitor")
    assert_equal run.id, current.id
    @connection.update!(monthly_budget_cents: 0)
    assert_equal run.id, current.id
    assert run.visible_to?(user: @owner)
    @finding.update!(active: false)
    assert_nil current
    refute run.visible_to?(user: @owner)
  end

  test "only a member permitted to share current scoped data may ask or read" do
    other = User.create!(email: "other@example.test", password: "a-long-fixture-password")
    assert_raises(ActiveRecord::RecordInvalid) { AiRun.request_page_advice!(finding: @finding, user: other) }
    @workspace.memberships.create!(user: other, role: "manager")
    assert_raises(ActiveRecord::RecordInvalid) { AiRun.request_page_advice!(finding: @finding, user: other) }
    @setting.update!(managers_enabled: true)
    run = request
    manager_run = AiRun.request_page_advice!(finding: @finding, user: other)
    assert_not_equal manager_run.id, run.id
    refute run.visible_to?(user: other)
    @setting.update!(share_google: false)
    assert_nil current
    @job.perform(run.id)
    assert_equal "cancelled", run.reload.status
    assert_empty @requests
  end

  test "a new evidence snapshot cancels an old reservation and can be requested immediately" do
    run = request
    payload = @job.send(:reserve, @connection, run)
    assert payload
    assert_operator @connection.month_spend_microusd, :>, 0
    revised = @finding.evidence.deep_dup
    revised.fetch("clicks")["current"] += 1
    @finding.update!(evidence: revised)
    @job.send(:dispatch, @connection, run, payload)
    assert_equal ["cancelled", 0], run.reload.attributes.values_at("status","actual_microusd")
    assert_nil current
    assert_not_equal run.id, request.id
    assert_empty @requests
  end

  test "losing manager access after reservation releases it before dispatch" do
    @setting.update!(managers_enabled: true)
    manager = User.create!(email: "manager@example.test", password: "a-long-fixture-password")
    membership = @workspace.memberships.create!(user: manager, role: "manager")
    run = AiRun.request_page_advice!(finding: @finding, user: manager)
    payload = @job.send(:reserve, @connection, run)
    assert payload
    membership.update!(role: "viewer")
    @job.send(:dispatch, @connection, run, payload)
    assert_equal ["cancelled", 0], run.reload.attributes.values_at("status", "actual_microusd")
    assert_nil AiRun.current_page_advice(finding: @finding, user: manager)
    assert_empty @requests
  end

  test "withdrawn grant and changed reporting country prevent sending" do
    run = request
    @site.update!(rank_country_code: "US")
    assert_nil current
    assert_raises(ActiveRecord::RecordInvalid) { request }
    @site.update!(rank_country_code: "GB")
    @gsc.update!(ai_grant_revision: SecureRandom.uuid)
    @job.perform(run.id)
    assert_nil run.reload.site_finding_id
    assert_equal "cancelled", run.status
    assert_empty @requests
  end

  test "explicit retry acts on one definitively uncharged receipt only" do
    first = request
    @connection.update!(monthly_budget_cents: 0)
    @job.perform(first.id)
    assert first.reload.page_advice_retryable?
    @connection.update!(monthly_budget_cents: 20)
    assert_equal first.id, request.id
    second = request(retry_run_id: first.id)
    assert_not_equal first.id, second.id
    assert_equal second.id, request(retry_run_id: first.id).id
    second.update!(status: "failed", actual_microusd: nil, failure_code: "uncertain")
    assert_equal second.id, request(retry_run_id: second.id).id
    assert_empty @requests
  end

  test "one eligible action stays local and erasure retains usage receipts" do
    @finding.update!(level: "limited")
    run = request
    @job.perform(run.id)
    assert_equal ["fallback", "one_supported_choice", 0], run.reload.attributes.values_at("status","failure_code","actual_microusd")
    assert_equal "monitor", run.answer["decision_key"]
    assert_empty @requests
    run.erase_content!
    assert_nil current
    assert_not_equal run.id, request.id
    assert_equal({}, run.reload.evidence)
  end

  test "an unusable answer with a confirmed charge permits a deliberate new attempt and keeps both receipts" do
    first = request
    adapter = Object.new
    adapter.define_singleton_method(:call) do |**|
      AiAssistant::OpenaiClient::Response.new({"decision_key" => "unknown_option"}, 110, 10, 120, "req_unusable")
    end
    failing_job = AiRunJob.new
    failing_job.define_singleton_method(:provider) { adapter }
    failing_job.perform(first.id)
    assert_equal ["fallback", "invalid_response", 120], first.reload.attributes.values_at("status", "failure_code", "actual_microusd")
    assert first.page_advice_retryable?
    assert_equal first.id, request.id
    second = request(retry_run_id: first.id)
    assert_not_equal first.id, second.id
    assert_equal second.id, request(retry_run_id: first.id).id
    @job.perform(second.id)
    assert_equal "complete", second.reload.status
    assert_equal 136, @connection.month_spend_microusd
    assert_equal second.id, request(retry_run_id: first.id).id
    assert_equal second.id, request(retry_run_id: second.id).id
    first.actual_microusd = nil
    refute first.page_advice_retryable?
    second.erase_content!
    assert_nil current
    assert first.reload.erased_at
    assert_equal({}, first.answer)
    assert_empty second.reload.evidence
    assert_equal 136, @connection.month_spend_microusd
    fresh = request
    first.erase_content!
    assert_equal fresh.id, current.id
  end
end
