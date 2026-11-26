class TrackingScheduleJob < ApplicationJob
  queue_as :default

  def perform
    now = Time.current
    TrackingSeries.current.where(paused: false).find_each do |series|
      local = now.in_time_zone(series.settings.fetch("time_zone"))
      today = local.to_date
      last_day = series.daily_slots.maximum(:day) || (series.enrolled_on - 1)
      if last_day < today - 1
        (last_day + 1...today).each_slice(90) do |days|
          DailySlot.insert_all(days.map { |day| { tracking_series_id: series.id, day: day, status: "missing", reason: "No scheduled observation" } },
            unique_by: [:tracking_series_id, :day])
        end
      end
      series.daily_slots.where(status: "pending", day: ...today).update_all(status: "missing", reason: "No observation on this date", updated_at: now)
      series.daily_slots.create_or_find_by!(day: today) if local.hour >= 8 && today >= series.enrolled_on
    end

    due = DailySlot.joins(:tracking_series).where(tracking_series: { archived_at: nil, paused: false })
      .where.not(tracking_series: { source: "manual" })
      .where(status: %w[pending submitted dispatching held])
      .where("retry_after IS NULL OR retry_after <= ?", now)
      .where("last_queued_at IS NULL OR last_queued_at < ?", now - 3.minutes)
    due.find_each do |slot|
      next if slot.status == "held" && slot.attempted_at.blank? && slot.tracking_series.source == "dataforseo" && !Tracking::DataForSeo.enabled?
      next if slot.status == "held" && slot.attempted_at && slot.attempted_at < 2.days.ago
      # The slot is a persistent outbox. A crash before enqueue releases this short delivery lease automatically.
      leased = DailySlot.where(id: slot.id).where("last_queued_at IS NULL OR last_queued_at < ?", now - 3.minutes).update_all(last_queued_at: now)
      TrackingCollectJob.perform_later(slot.id) if leased == 1
    end
  end
end
