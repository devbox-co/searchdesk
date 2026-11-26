require "test_helper"

class SchedulesWorkflowsTest < ActiveSupport::TestCase
  setup do
    @now = Time.utc(2026, 11, 25, 10, 40)
    @workspace = Workspace.create!(name: "Clinic workspace")
    @site = @workspace.sites.create!(name: "Clinic", host: "clinic.example", location: "Town", time_zone: "Europe/London")
  end

  def schedule(key, now: @now)
    Schedules::Workflows.new(site: @site, now: now).rows.index_by { |row| row[:key] }.fetch(key)
  end

  test "site settings and audit receipts are scoped and timing follows the request not the finish" do
    started = @now - 12.minutes
    ended = started + 2.minutes
    @site.update!(weekly_site_audit_enabled: true)
    SiteAudit.create!(site: @site, status: "complete", host: @site.host, created_at: started, started_at: started + 2.seconds, finished_at: ended)
    SiteAudit.create!(site: @site, status: "failed", host: "previous.example", created_at: @now, finished_at: @now)
    other = @workspace.sites.create!(host: "other.example", name: "Other", location: "Town")
    SiteAudit.create!(site: other, host: other.host, status: "failed", created_at: @now, finished_at: @now)
    assert_no_difference -> { SiteAudit.count } do
      row = schedule("site_audit")
      assert_equal "Enabled", row[:status]
      assert_equal ended, row[:last_at]
      assert_equal "Manual crawl · complete", row[:last_label]
      assert_equal started + 7.days, row[:next_at]
    end
    @site.update!(weekly_site_audit_enabled: false)
    assert_nil schedule("site_audit")[:next_at]
    assert_equal ended, schedule("site_audit")[:last_at]
  end

  test "ranking rows distinguish imports, initial paid setup, demo observations and paused series" do
    assert_equal "Manual imports", schedule("rankings")[:status]
    travel_to @now do
      @site.update!(tracking_mode: "demo")
      kw = Tracking::Enrollment.call(site: @site, phrase: "repairs", devices: ["mobile"])
      row = schedule("rankings")
      assert_equal "Demo data", row[:status]
      assert_equal @now, row[:last_at]
      assert_equal Time.utc(2026, 11, 26, 8), row[:next_at]
      assert_match(/1 of 1/, row[:detail])
      kw.tracking_series.sole.update!(paused: true)
      assert_equal "Paused", schedule("rankings")[:status]
    end
  end

  test "paid collection respects provider scope and retry time while hiding credentials" do
    keys = %w[DATAFORSEO_ENABLED DATAFORSEO_LOGIN DATAFORSEO_PASSWORD DATAFORSEO_ALLOWED_SERIES_IDS DATAFORSEO_DAILY_TASK_LIMIT DATAFORSEO_31_DAY_TASK_LIMIT]
    previous = keys.to_h { |key| [key, ENV[key]] }
    travel_to @now do
      @site.update!(tracking_mode: "dataforseo", rank_location_code: 123, rank_location_name: @site.location, rank_location_verified_at: @now)
      series = Tracking::Enrollment.call(site: @site, phrase: "repairs", devices: ["mobile"]).tracking_series.sole
      ENV.update("DATAFORSEO_ENABLED" => "true", "DATAFORSEO_LOGIN" => "test-account", "DATAFORSEO_PASSWORD" => "test-secret",
        "DATAFORSEO_ALLOWED_SERIES_IDS" => "", "DATAFORSEO_DAILY_TASK_LIMIT" => "1", "DATAFORSEO_31_DAY_TASK_LIMIT" => "30")
      assert_equal "Collection blocked", schedule("rankings")[:status]
      ENV["DATAFORSEO_ALLOWED_SERIES_IDS"] = series.id.to_s
      series.daily_slots.sole.update!(status: "held", reason: "Daily provider task limit reached", retry_after: @now + 1.hour)
      row = schedule("rankings")
      assert_match(/hold/, row[:status])
      assert_equal @now + 1.hour, row[:next_at]
      assert_equal "Collection put on hold", row[:last_label]
      assert_not_includes row.to_s, "test-secret"
      # A different site can consume the shared allowance, without its name
      # or counts appearing here. Check the earliest candidate submission time.
      other = @workspace.sites.create!(host: "other.example", name: "Other", location: "Town")
      reserved = Tracking::Enrollment.call(site: other, phrase: "other term", devices: ["mobile"]).tracking_series.sole.daily_slots.sole
      reserved.update!(attempted_at: @now - 1.minute)
      assert_equal "Submission limit reached", schedule("rankings")[:status]
      assert_match(/UTC daily task limit/, schedule("rankings")[:detail])
      assert_nil schedule("rankings")[:next_at]
      reserved.update!(attempted_at: @now - 2.days)
      ENV["DATAFORSEO_31_DAY_TASK_LIMIT"] = "1"
      assert_match(/rolling 31-day task limit/, schedule("rankings")[:detail])
      # A prior-day paid request is still polled while today's new submission is blocked.
      series.daily_slots.create!(day: @now.yesterday.to_date, status: "submitted", attempted_at: @now - 1.day, retry_after: @now + 4.minutes)
      assert_equal "Checking existing requests", schedule("rankings")[:status]
      assert_equal @now + 4.minutes, schedule("rankings")[:next_at]
      ENV["DATAFORSEO_ENABLED"] = "false"
      assert_equal "Provider disabled", schedule("rankings")[:status]
    end
  ensure
    previous&.each { |key, value| ENV[key] = value }
  end

  test "brief shows optional configuration and waits for unsettled readings before local noon" do
    assert_equal "Off", schedule("daily_brief")[:status]
    @site.create_ai_setting!(enabled: true, daily_brief_enabled: true)
    assert_equal "OpenAI setup needed", schedule("daily_brief")[:status]
    connection = @workspace.create_ai_connection!(api_key: "sk-test-schedules", monthly_budget_cents: 100)
    assert_equal "Connection test needed", schedule("daily_brief")[:status]
    connection.update!(status: "ready")
    travel_to @now do
      @site.update!(tracking_mode: "demo")
      k = Tracking::Enrollment.call(site: @site, phrase: "glass", devices: ["mobile"])
      k.tracking_series.sole.daily_slots.find_by!(day: @now.to_date).update!(status: "pending")
      @site.reload
      assert_equal "Waiting for rankings", schedule("daily_brief")[:status]
      assert_nil schedule("daily_brief")[:next_at]
      assert_match(/Eligible at the next/, schedule("daily_brief", now: @now.change(hour: 12))[:next_label])
      connection.update!(monthly_budget_cents: 0)
      assert_equal "Allowance paused", schedule("daily_brief")[:status]
    end
  end

  test "daily brief history excludes private questions and uses tomorrow after a run even if its content was erased" do
    @site.create_ai_setting!(enabled: true, daily_brief_enabled: true)
    @workspace.create_ai_connection!(api_key: "sk-test-schedules", monthly_budget_cents: 100).update!(status: "ready")
    @site.reload
    @site.ai_runs.create!(kind: "brief", request_key: "brief/day", report_on: @now.to_date, status: "fallback", finished_at: @now)
    @site.ai_runs.create!(kind: "question", request_key: "question/1", report_on: @now.to_date,
      status: "complete", question: "Private question", finished_at: @now)
    row = schedule("daily_brief")
    assert_equal "Local-evidence brief published", row[:last_label]
    assert_equal @now, row[:last_at]
    assert_equal @now.tomorrow.change(hour: 9), row[:next_at]
    assert_not_includes row.to_s, "Private question"
    @site.ai_runs.find_by!(kind: "brief").update!(erased_at: @now)
    assert_nil schedule("daily_brief")[:last_at]
    assert_equal @now.tomorrow.change(hour: 9), schedule("daily_brief")[:next_at]
  end
end
