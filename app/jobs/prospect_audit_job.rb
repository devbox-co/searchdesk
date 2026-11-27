class ProspectAuditJob < ApplicationJob
  PAGE_LIMIT = 5
  FINDING_PRIORITY = %w[noindex http_error broken_link missing_title missing_h1 missing_description
    missing_canonical duplicate_title multiple_h1 fetch_error redirect_unfollowed].freeze

  def perform(id)
    claimed = ProspectAudit.where(id: id, website_status: "queued")
      .update_all(website_status: "running", updated_at: Time.current)
    return if claimed.zero?

    audit = ProspectAudit.find_by(id: id)
    return unless audit
    unless audit.authorised?
      audit.update!(website_status: "failed", provider_status: audit.provider_status == "queued" ? "failed" : audit.provider_status)
      return
    end

    result = SiteAudits::Crawler.new(host: audit.target_host, page_limit: PAGE_LIMIT).call
    counts = result.fetch("summary").slice("pages_checked", "html_pages", "robots_blocked")
    priority = Array(result["issues"]).sort_by { |issue| FINDING_PRIORITY.index(issue["code"]) || FINDING_PRIORITY.size }
    findings = priority.first(5).map { |issue| issue.slice("code", "count", "paths") }
    status = counts.fetch("html_pages").zero? ? "failed" : result.fetch("status")
    audit.update!(website_status: status, website_report: { "counts" => counts, "findings" => findings,
      "coverage_note" => result["stop_reason"] })
    ProspectAuditProviderJob.perform_later(audit.id) if audit.provider_status == "queued"
  rescue StandardError
    if claimed == 1
      ProspectAudit.where(id: id, website_status: "running").update_all(website_status: "failed", updated_at: Time.current)
    end
    raise
  end
end
