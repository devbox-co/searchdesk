require "test_helper"

class AiRunJobTest < ActiveJob::TestCase
  setup do
    @workspace = Workspace.create!(name: "Example workspace")
    @site = @workspace.sites.create!(name: "Public Fixture Business", host: "fixture.test",
      location: "London", language: "en", time_zone: "Europe/London", tracking_mode: "manual")
    @owner = User.create!(email: "owner@example.test", password: "a-long-fixture-password")
    @workspace.memberships.create!(user: @owner, role: "owner")
    @connection = @workspace.create_ai_connection!(api_key: "sk-test-fixture", monthly_budget_cents: 100)
    @setting = @site.create_ai_setting!(enabled: true, daily_brief_enabled: true, priorities: "Measure search visibility.")
    @calls = []
    @job = AiRunJob.new
    calls = @calls
    adapter = Object.new
    adapter.define_singleton_method(:call) do |api_key:, payload:|
      raise "Missing fixture key" unless api_key == "sk-test-fixture"
      calls << JSON.parse(payload.json)
      first = payload.facts.first
      choices = first ? [{ "fact_ids" => [first.fetch("id")], "next_check" => "none" }] : []
      AiAssistant::OpenaiClient::Response.new({ "findings" => choices }, 100, 10, 15, "req_fixture")
    end
    @job.define_singleton_method(:provider) { adapter }
  end

  def request(kind = "test", **args)
    AiRun.request!(site: @site, user: kind == "brief" ? nil : @owner, kind: kind, **args)
  end

  test "only a successful synthetic test verifies the key and duplicate deliveries charge once" do
    @setting.destroy!
    test_run = request
    2.times { @job.perform(test_run.id) }
    assert_equal 1, @calls.size
    refute_includes @calls.first.fetch("input"), @site.name
    assert_equal ["complete", 15, "req_fixture"], test_run.reload.attributes.values_at("status", "actual_microusd", "provider_request_id")
    assert_equal "ready", @connection.reload.status
    assert @connection.last_verified_at
    assert_equal 15, @connection.month_spend_microusd
  end

  test "fresh site questions can use a cited prior question or a published brief in the same site" do
    @connection.update!(status: "ready")
    first = request("question", question: "What are our business goals?")
    @job.perform(first.id)
    assert_equal "complete", first.reload.status
    assert first.answer.fetch("findings").first.fetch("fact_ids").any?
    followup = request("question", question: "What about that?", parent: first)
    @job.perform(followup.id)
    assert_equal first.question, JSON.parse(@calls.last.fetch("input")).dig("previous", "question")
    brief = request("brief")
    @job.perform(brief.id)
    from_brief = request("question", question: "What does this mean?", parent: brief.reload)
    @job.perform(from_brief.id)
    assert_equal "brief", JSON.parse(@calls.last.fetch("input")).dig("previous", "kind")
    assert_equal 4, @calls.size
  end

  test "rotation after reservation prevents dispatch and releases unspent budget" do
    run = request
    payload = @job.send(:reserve, @connection, run)
    assert payload
    assert_operator @connection.month_spend_microusd, :>, 0
    @connection.update!(api_key: "sk-different-fixture")
    @job.send(:dispatch, @connection, run, payload)
    assert_empty @calls
    assert_equal ["cancelled", 0], run.reload.attributes.values_at("status", "actual_microusd")
  end

  test "a guided investigation with no matching evidence completes locally" do
    @connection.update!(status: "ready")
    run = request("question", question: AiAssistant::Playbooks.find("weekly_clicks").question)
    @job.perform(run.id)
    assert_empty @calls
    assert_equal ["complete", 0], run.reload.attributes.values_at("status", "actual_microusd")
    assert_nil run.attempted_at
    assert_empty run.answer.fetch("findings").first.fetch("fact_ids")
  end

  test "zero cap rejects dispatch and an uncertain request is never retried" do
    @connection.update!(monthly_budget_cents: 0)
    stopped = request
    @job.perform(stopped.id)
    assert_equal "budget", stopped.reload.status
    assert_nil stopped.attempted_at
    assert_empty @calls

    @connection.update!(monthly_budget_cents: 100)
    uncertain = request
    adapter = Object.new
    calls = @calls
    adapter.define_singleton_method(:call) do |**|
      calls << :unknown
      raise AiAssistant::OpenaiClient::Error.new("unavailable")
    end
    @job.define_singleton_method(:provider) { adapter }
    2.times { @job.perform(uncertain.id) }
    assert_equal [:unknown], @calls
    assert_equal "failed", uncertain.reload.status
    assert_nil uncertain.actual_microusd
    assert_equal uncertain.reserved_microusd, @connection.month_spend_microusd
    assert_equal "untested", @connection.reload.status
  end

  test "invalid references fall back to local facts while preserving usage" do
    @connection.update!(status: "ready")
    run = request("question", question: "What are this site's goals?")
    adapter = Object.new
    adapter.define_singleton_method(:call) do |**|
      AiAssistant::OpenaiClient::Response.new({"findings" => [{"fact_ids" => ["BAD"], "next_check" => "none"}]},
        75, 20, 18, "req_invalid")
    end
    @job.define_singleton_method(:provider) { adapter }
    @job.perform(run.id)
    assert_equal ["fallback", "invalid_response", 18], run.reload.attributes.values_at("status", "failure_code", "actual_microusd")
    refute run.answer.to_json.include?("BAD")
    assert run.answer.fetch("findings").any?
  end

  test "outstanding reservations across sites consume one workspace cap" do
    @connection.update!(monthly_budget_cents: 1)
    other = @workspace.sites.create!(name: "Second fixture", host: "second.test", location: "London",
      language: "en", time_zone: "Europe/London", tracking_mode: "manual")
    # Leave claims in flight so another site cannot spend those reservations.
    runs = Array.new(8) do |index|
      run = AiRun.request!(site: index.even? ? @site : other, user: @owner, kind: "test")
      @job.send(:reserve, @connection, run)
      run.reload
    end
    assert runs.any? { |run| run.status == "budget" }
    assert_equal [@site.id, other.id].sort, runs.select { |r| r.status == "running" }.map(&:site_id).uniq.sort
    assert_operator @connection.month_spend_microusd, :<=, 10_000
    first = runs.find { |r| r.status == "running" }
    assert_operator @connection.month_spend_microusd + first.reserved_microusd, :>, 10_000
    assert_empty @calls
  end

  test "a scheduled brief waits for collection until the local cutoff and never backfills sleeping days" do
    @connection.update!(status: "ready")
    @site.update!(tracking_mode: "dataforseo", rank_location_verified_at: Time.current,
      rank_location_name: @site.location, rank_location_code: 123, rank_country_code: "GB")
    travel_to Time.utc(2026, 7, 20, 7, 45) do
      Tracking::Enrollment.call(site: @site, phrase: "Service", devices: ["mobile"])
      AiBriefScheduleJob.perform_now
      assert_empty @site.ai_runs
    end
    travel_to Time.utc(2026, 7, 20, 8, 15) do
      AiBriefScheduleJob.perform_now
      assert_empty @site.ai_runs
    end
    travel_to Time.utc(2026, 7, 20, 11, 15) do
      2.times { AiBriefScheduleJob.perform_now }
      assert_equal Date.new(2026, 7, 20), @site.ai_runs.sole.report_on
    end
    travel_to Time.utc(2026, 7, 23, 12) do
      first = @site.ai_runs.sole
      AiBriefScheduleJob.perform_now
      assert_equal "expired", first.reload.status
      assert_equal [Date.new(2026, 7, 20), Date.new(2026, 7, 23)], @site.ai_runs.order(:report_on).pluck(:report_on)
      assert_empty @calls
    end
  end

  test "recovery retains ambiguous reservations and does not queue a second generation" do
    run = request
    payload = @job.send(:reserve, @connection, run)
    assert payload
    travel 11.minutes do
      AiBriefScheduleJob.perform_now
      @job.perform(run.id)
      assert_equal ["failed", "uncertain", nil], run.reload.attributes.values_at("status", "failure_code", "actual_microusd")
      assert_equal run.reserved_microusd, @connection.month_spend_microusd
      assert_empty @calls
    end
  end
end
