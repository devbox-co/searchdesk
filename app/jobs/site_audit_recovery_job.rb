class SiteAuditRecoveryJob < ApplicationJob
  def perform
    # The crawl has a two-minute time budget. A worker missing for this long cannot still own a live crawl.
    SiteAudit.where(status: "running", started_at: ...10.minutes.ago).update_all(status: "failed", finished_at: Time.current,
      updated_at: Time.current, failure_reason: "The worker was interrupted. Start a new crawl to collect a fresh sample.")
    SiteAudit.where(status: "queued", created_at: ...2.minutes.ago).find_each { |audit| SiteAuditJob.perform_later(audit.id) }
    Site.where(weekly_site_audit_enabled: true).find_each { |site| SiteAudit.request!(site: site, weekly: true) }
  end
end
