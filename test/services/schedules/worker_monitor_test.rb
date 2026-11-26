require "test_helper"

class SchedulesWorkerMonitorTest < ActiveSupport::TestCase
  test "only recent worker, scheduler and dispatcher heartbeats establish live scheduling" do
    now = Time.utc(2026, 8, 17, 11, 0)
    Schedules::WorkerMonitor::PROCESS_KINDS.each_with_index do |kind, i|
      SolidQueue::Process.insert_all!([{ kind: kind, name: "schedule-test-#{kind}", pid: 100 + i,
        last_heartbeat_at: now - 1.minute, created_at: now - 5.minutes }])
    end
    assert Schedules::WorkerMonitor.online?(now: now)
    SolidQueue::Process.where(kind: "Scheduler").update_all(last_heartbeat_at: now - 4.minutes)
    assert_not Schedules::WorkerMonitor.online?(now: now)
  end

  test "registered checks use completion receipts and exclude other jobs" do
    now = Time.utc(2026, 8, 17, 11, 0)
    SolidQueue::RecurringTask.create!(key: "site_audit_recovery", schedule: "every 10 minutes", class_name: "SiteAuditRecoveryJob")
    SolidQueue::RecurringTask.create!(key: "analytics_daily", schedule: "every 15 minutes", class_name: "AnalyticsSyncJob")
    record_tick("site_audit_recovery", now - 10.minutes, finished: now - 9.minutes)
    record_tick("site_audit_recovery", now - 5.seconds, finished: nil)
    record_tick("private_job", now - 1.minute, finished: now - 10.seconds)
    monitor = Schedules::WorkerMonitor.new(now: now)
    rows = monitor.checks.index_by { |row| row[:name] }
    assert_equal now - 9.minutes, monitor.health[:last_tick]
    assert_equal now - 9.minutes, rows.fetch("Site audit scheduling and recovery")[:last_check]
    assert_equal "Every 10 minutes", rows.fetch("Site audit scheduling and recovery")[:frequency]
    assert_nil rows.fetch("Google Analytics refresh")[:last_check]
    assert_equal 2, rows.size
  end

  private

  def record_tick(key, scheduled, finished:)
    id = SolidQueue::Job.insert_all!([{class_name: "FixtureJob", queue_name: "default", finished_at: finished,
      created_at: scheduled, updated_at: finished || scheduled}], returning: %i[id]).rows.first.first
    SolidQueue::RecurringExecution.create!(job_id: id, task_key: key, run_at: scheduled)
  end
end
