class ProspectAuditRecoveryJob < ApplicationJob
  def perform
    now = Time.current
    stale = now - 3.minutes
    ProspectAudit.where(website_status: "running", updated_at: ..stale)
      .update_all(website_status: "failed", updated_at: now)
    ProspectAudit.where(provider_status: "submitting", updated_at: ..stale)
      .update_all(provider_status: "unconfirmed", updated_at: now)
    ProspectAudit.where(website_status: "queued", updated_at: ..stale).find_each do |audit|
      ProspectAuditJob.perform_later(audit.id)
    end
    ProspectAudit.where(website_status: %w[complete partial failed], provider_status: "queued", updated_at: ..stale)
      .or(ProspectAudit.where(provider_status: "pending", next_poll_at: ..now)).find_each do |audit|
      ProspectAuditProviderJob.perform_later(audit.id)
    end
  end
end
