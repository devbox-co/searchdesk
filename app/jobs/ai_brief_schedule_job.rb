class AiBriefScheduleJob < ApplicationJob
  TERMINAL_SLOT_STATES = %w[ranked outside incomplete failed missing].freeze

  def perform
    recover_jobs
    return unless AiConnection.owner_controlled_installation?
    AiSetting.where(enabled: true, daily_brief_enabled: true).includes(site: { workspace: :ai_connection }).find_each do |setting|
      site = setting.site
      connection = site.workspace.ai_connection
      next unless connection&.configured? && connection.status == "ready"

      local = Time.current.in_time_zone(site.time_zone)
      next if local.hour < 9
      day = local.to_date
      next if local.hour < 12 && waiting_for_collection?(site, day)
      next if AiRun.exists?(site: site, kind: "brief", report_on: day)

      run = AiRun.request!(site: site, user: nil, kind: "brief", report_on: day)
      AiRunJob.perform_later(run.id) if run.status == "pending"
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound
      # Settings, a site's connection or its eligibility may change during a sweep.
      next
    end
  end

  private

  def waiting_for_collection?(site, day)
    return false if site.tracking_mode == "manual"
    active = TrackingSeries.current.where(keyword_id: site.keywords.select(:id), paused: false, source: site.tracking_mode, enrolled_on: ..day)
    settled = DailySlot.where(day: day, status: TERMINAL_SLOT_STATES).select(:tracking_series_id)
    active.where.not(id: settled).exists?
  end

  def recover_jobs
    now = Time.current
    AiRun.where(status: "running", attempted_at: ...10.minutes.ago)
      .update_all(status: "failed", failure_code: "uncertain", finished_at: now, updated_at: now)
    AiRun.where(status: "pending", created_at: ...AiRunJob::MAX_PENDING_AGE.ago)
      .update_all(status: "expired", failure_code: "stale", actual_microusd: 0, finished_at: now, updated_at: now)
    # Recover a commit followed by a queue outage. The worker's durable reservation deduplicates deliveries.
    AiRun.where(status: "pending", created_at: ...1.minute.ago).find_each { |run| AiRunJob.perform_later(run.id) }
  end
end
