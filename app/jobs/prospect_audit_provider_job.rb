class ProspectAuditProviderJob < ApplicationJob
  POLL_INTERVAL = 15.seconds
  MAX_POLLS = 12

  def perform(id)
    audit = ProspectAudit.find_by(id: id)
    return unless audit && %w[queued pending].include?(audit.provider_status)
    return unless %w[complete partial failed].include?(audit.website_status)

    unless audit.authorised? && ProspectAudit.provider_enabled?(audit.site)
      audit.update!(provider_status: "failed")
      return
    end

    if audit.provider_status == "queued"
      submit(audit)
    else
      poll(audit)
    end
  end

  private

  def submit(audit)
    claimed = ProspectAudit.where(id: audit.id, provider_status: "queued")
      .update_all(provider_status: "submitting", updated_at: Time.current)
    return if claimed.zero?

    reference = LocalSeoData::Client.new.submit_prospect(business_name: audit.business_name, market: audit.market)
    submitted = audit.with_lock do
      next unless audit.provider_status == "submitting"

      audit.update!(provider_status: "pending", provider_job_id: reference, next_poll_at: POLL_INTERVAL.from_now)
    end
    schedule(audit) if submitted
  rescue LocalSeoData::Client::Unavailable
    ProspectAudit.where(id: audit.id, provider_status: "submitting")
      .update_all(provider_status: "unconfirmed", updated_at: Time.current)
  end

  def poll(audit)
    claimed = audit.with_lock do
      next unless audit.provider_status == "pending" && audit.next_poll_at && audit.next_poll_at <= Time.current

      if audit.provider_poll_count >= MAX_POLLS
        audit.update!(provider_status: "unconfirmed", next_poll_at: nil)
        next
      end
      # Free polling can safely resume after a crash, but each poll still reserves one slot.
      audit.update!(provider_poll_count: audit.provider_poll_count + 1, next_poll_at: 3.minutes.from_now)
    end
    return unless claimed

    data = LocalSeoData::Client.new.poll_prospect(audit.provider_job_id)
    case data.fetch("status")
    when "complete"
      audit.update!(provider_status: "complete", provider_report: LocalSeoData::ProspectSummary.build(data), next_poll_at: nil)
    when "failed"
      audit.update!(provider_status: "failed", next_poll_at: nil)
    else
      continue_polling(audit)
    end
  rescue LocalSeoData::Client::Unavailable
    continue_polling(audit)
  end

  def continue_polling(audit)
    audit.update!(next_poll_at: POLL_INTERVAL.from_now)
    schedule(audit)
  end

  def schedule(audit)
    self.class.set(wait_until: audit.next_poll_at).perform_later(audit.id)
  end
end
