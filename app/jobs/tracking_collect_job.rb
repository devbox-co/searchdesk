class TrackingCollectJob < ApplicationJob
  queue_as :default

  def perform(slot_id)
    slot = DailySlot.find_by(id: slot_id)
    return unless slot
    series = slot.tracking_series
    return if series.paused || series.archived_at || series.source == "manual"
    if series.site.tracking_mode != series.source
      return hold(slot, "Site collection mode changed; enrol the new configuration", 12.hours)
    end
    return unless %w[pending submitted held dispatching].include?(slot.status)
    return if slot.retry_after && slot.retry_after > Time.current
    if series.source == "demo"
      Tracking::DemoHistory.fill(series, from: slot.day, through: slot.day)
      return
    end

    return hold(slot, "Provider connection is disabled", 30.minutes) unless Tracking::DataForSeo.enabled?
    return hold(slot, "Verify the town and country, then enrol this configuration", 12.hours) unless series.settings["location_code"].to_i.positive?
    provider = provider_adapter
    if slot.task_id.present?
      poll(slot, provider)
    elsif slot.attempted_at
      recovered = provider.recover(slot)
      recovered ? bind_task(slot, recovered) : hold(slot, "Submission unconfirmed; reconciling without resubmission", 30.minutes)
    elsif slot.day != series.date_in_zone
      slot.update!(status: "missing", reason: "No observation on this date")
    elsif reserve_submission(slot)
      submit_reserved(slot, provider)
    end
  rescue Tracking::DataForSeo::Unavailable, KeyError, TypeError => e
    hold(slot, "Provider temporarily unavailable; check scheduled", 15.minutes) if slot
  rescue Tracking::DataForSeo::Rejected, Tracking::DataForSeo::ScopeError, Tracking::RecordResult::Error => e
    update_unfinished(slot) { slot.update!(status: "failed", reason: e.message) } if slot
  rescue ActiveRecord::RecordNotFound
    nil
  end

  private

  def provider_adapter
    Tracking::DataForSeo.new
  end

  def reserve_submission(slot)
    DailySlot.transaction do
      DailySlot.connection.execute("SELECT pg_advisory_xact_lock(624003017)")
      slot.lock!
      return false unless slot.task_id.nil? && slot.attempted_at.nil? && %w[held pending].include?(slot.status)
      unless Tracking::DataForSeo.series_allowed?(slot.tracking_series_id)
        hold(slot, "This series is outside the authorized provider scope", 12.hours)
        return false
      end
      now = Time.current.utc
      if DailySlot.where(attempted_at: now.beginning_of_day..).count >= Tracking::DataForSeo.daily_task_limit
        hold(slot, "Daily provider task limit reached", 1.hour)
        return false
      end
      # A rolling 31 × 24h interval can include parts of 32 UTC calendar dates.
      # Count every reservation, including interrupted and unconfirmed submissions.
      if DailySlot.where("attempted_at > ?", now - 31.days).count >= Tracking::DataForSeo.rolling_task_limit
        hold(slot, "Rolling 31-day provider task limit reached", 5.minutes)
        return false
      end
      slot.update!(status: "dispatching", attempted_at: now, attempt_key: SecureRandom.uuid, retry_after: 3.minutes.from_now, reason: nil)
      true
    end
  end

  # The attempt key is already committed. A process failure while the provider is accepting a task
  # therefore leaves a recoverable attempt, even if this second transaction never commits.
  def submit_reserved(slot, provider)
    series = slot.tracking_series
    site = series.site
    site.with_lock do
      series.lock!
      slot.lock!
      return unless slot.status == "dispatching" && slot.attempt_key && !slot.task_id
      unless Tracking::DataForSeo.enabled? && Tracking::DataForSeo.series_allowed?(series.id) &&
             Tracking::DataForSeo.daily_task_limit.positive? && Tracking::DataForSeo.rolling_task_limit.positive? &&
             site.tracking_mode == "dataforseo" && !series.paused &&
             !series.archived_at && slot.day == series.date_in_zone && site.rank_location_code == series.settings["location_code"]
        slot.update!(status: "pending", attempted_at: nil, attempt_key: nil, retry_after: nil, reason: "Collection configuration changed before submission")
        return
      end
      bind_task(slot, provider.submit(slot))
    end
  end

  def update_unfinished(slot)
    slot.with_lock do
      yield unless slot.rank_observation || %w[failed missing].include?(slot.status)
    end
  end

  def bind_task(slot, id)
    update_unfinished(slot) do
      return if slot.task_id.present?
      slot.update!(task_id: id, status: "submitted", retry_after: 2.minutes.from_now, reason: nil)
    end
  end

  def poll(slot, provider)
    if slot.poll_attempts >= 30
      update_unfinished(slot) { slot.update!(status: "failed", reason: "No comparable result before polling limit") }
      return
    end
    data = provider.poll(slot)
    if data
      Tracking::RecordResult.call(series: slot.tracking_series, expected_day: slot.day, **data)
    else
      update_unfinished(slot) { slot.update!(status: "submitted", poll_attempts: slot.poll_attempts + 1, retry_after: 5.minutes.from_now) }
    end
  end

  def hold(slot, reason, delay)
    update_unfinished(slot) { slot.update!(status: "held", reason: reason, retry_after: delay.from_now) }
    false
  end
end
