class SiteAuditJob < ApplicationJob
  def perform(id)
    now = Time.current
    claimed = SiteAudit.where(id: id, status: "queued").update_all(status: "running", started_at: now, updated_at: now)
    return if claimed.zero?
    audit = SiteAudit.find_by(id: id)
    return unless audit
    unless audit.site.host == audit.host
      return finish(id, status: "failed", failure_reason: "The site address changed. Start a new crawl for the current site.")
    end
    if audit.trigger_kind == "weekly" && !audit.site.weekly_site_audit_enabled?
      return finish(id, status: "failed", failure_reason: "Weekly crawling was switched off before this run started.")
    end
    report = SiteAudits::Crawler.new(host: audit.host).call
    finish(id, status: report.fetch("status"), report: report, failure_reason: report["status"] == "failed" ? report["stop_reason"] : nil)
  rescue StandardError
    finish(id, status: "failed", failure_reason: "The crawl stopped unexpectedly. You can start a new crawl.") if claimed == 1
    raise
  end

  private

  def finish(id, attributes)
    SiteAudit.where(id: id, status: "running").update_all(attributes.merge(finished_at: Time.current, updated_at: Time.current))
  end
end
