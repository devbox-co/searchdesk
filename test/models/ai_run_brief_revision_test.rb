require "test_helper"

class AiRunBriefRevisionTest < ActiveJob::TestCase
  setup do
    workspace = Workspace.create!(name: "Daily brief fixture")
    @site = workspace.sites.create!(name: "Fixture business", host: "daily.example.test",
      location: "London", time_zone: "Europe/London", tracking_mode: "manual")
    @connection = workspace.create_ai_connection!(api_key: "sk-test-daily-brief", monthly_budget_cents: 100)
    @connection.update!(status: "ready")
    @setting = @site.create_ai_setting!(enabled: true, daily_brief_enabled: true)
  end

  test "a manual first brief uses the daily slot and a subsequent scheduled sweep leaves it alone" do
    travel_to Time.utc(2026, 7, 20, 12) do
      run = AiRun.request_current_brief!(site: @site)
      assert_equal "brief/2026-07-20", run.request_key
      assert_equal Date.new(2026, 7, 20), run.report_on
      assert_equal AiAssistant::Recipe.version("brief"), run.recipe_version
      assert_equal run, AiRun.request_current_brief!(site: @site)
      assert_no_enqueued_jobs(only: AiRunJob) { AiBriefScheduleJob.perform_now }
      assert_equal run, @site.ai_runs.sole
    end
  end

  test "a newer recipe creates its own receipt and reuses that receipt on repeat requests" do
    travel_to Time.utc(2026, 7, 20, 12) do
      original = AiRun.request!(site: @site, user: nil, kind: "brief")
      assert_equal original, AiRun.request_current_brief!(site: @site)
      original.update!(status: "complete", recipe_version: "brief-v1", attempted_at: Time.current,
        finished_at: Time.current, reserved_microusd: 500, actual_microusd: 32, provider_request_id: "req_first",
        answer: { "findings" => [{ "text" => "The original finding.", "fact_ids" => [] }] })
      receipt = original.reload.attributes.deep_dup

      assert_no_enqueued_jobs(only: AiRunJob) { AiBriefScheduleJob.perform_now }
      assert_equal 1, @site.ai_runs.count
      revised = AiRun.request_current_brief!(site: @site)
      assert_not_equal original.id, revised.id
      assert_not_equal original.request_key, revised.request_key
      assert_equal original.report_on, revised.report_on
      assert_equal "pending", revised.status
      assert_equal AiAssistant::Recipe.version("brief"), revised.recipe_version
      assert_nil revised.attempted_at
      assert_equal revised, AiRun.request_current_brief!(site: @site)
      # A terminal current-recipe attempt must also keep its original usage and identity.
      revised.update!(status: "fallback", failure_code: "unavailable", attempted_at: Time.current,
        finished_at: Time.current, reserved_microusd: 500, actual_microusd: nil)
      assert_equal revised, AiRun.request_current_brief!(site: @site)
      assert_no_enqueued_jobs(only: AiRunJob) { AiBriefScheduleJob.perform_now }
      assert_equal 2, @site.ai_runs.count
      assert_equal receipt, original.reload.attributes
      assert_equal 532, @connection.month_spend_microusd
    end
  end

  test "a request respects daily brief consent and a pending run stops when consent changes" do
    run = AiRun.request_current_brief!(site: @site)
    @setting.update!(daily_brief_enabled: false)
    AiRunJob.perform_now(run.id)
    assert_equal ["cancelled", "consent_changed", 0], run.reload.attributes.values_at("status", "failure_code", "actual_microusd")
    assert_nil run.attempted_at
    travel 1.day do
      assert_no_difference("AiRun.count") do
        assert_raises(ActiveRecord::RecordInvalid) { AiRun.request_current_brief!(site: @site) }
      end
    end
  end
end
