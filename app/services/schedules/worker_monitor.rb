module Schedules
  class WorkerMonitor
    # These are the application's shared checks. Only their timing is public to
    # the workspace; job arguments, individual executions and hostnames stay private.
    NAMES = {
      "tracking_slot_dispatch" => "Keyword rank collection",
      "search_console_daily" => "Search Console refresh",
      "analytics_daily" => "Google Analytics refresh",
      "local_falcon_daily" => "Local Falcon report refresh",
      "ai_daily_briefs" => "Daily brief scheduling",
      "site_audit_recovery" => "Site audit scheduling and recovery",
      "wording_recovery" => "Action wording recovery",
      "ai_evidence_cleanup" => "Assistant evidence cleanup",
      "clear_finished_jobs" => "Completed job cleanup"
    }.freeze
    PROCESS_KINDS = %w[Worker Scheduler Dispatcher].freeze

    def self.online?(now: Time.current)
      active = SolidQueue::Process.where(kind: PROCESS_KINDS, last_heartbeat_at: (now - 3.minutes)..now).distinct.pluck(:kind)
      (PROCESS_KINDS - active).empty?
    end

    def initialize(now: Time.current)
      @now = now
    end

    def health
      { status: self.class.online?(now: @now) ? :online : :offline, last_tick: last_completions.values.compact.max, checked_at: @now }
    end

    def checks
      registered = SolidQueue::RecurringTask.where(key: NAMES.keys).pluck(:key, :schedule).to_h
      NAMES.filter_map do |key, name|
        next unless registered.key?(key)
        { name: name, frequency: registered.fetch(key).upcase_first, last_check: last_completions[key] }
      end
    end

    private

    def last_completions
      @last_completions ||= SolidQueue::RecurringExecution.joins(:job).where(task_key: NAMES.keys)
        .where(solid_queue_jobs: { finished_at: ..@now }).group(:task_key).maximum("solid_queue_jobs.finished_at")
    end
  end
end
