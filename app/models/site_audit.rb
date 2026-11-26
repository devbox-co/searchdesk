class SiteAudit < ApplicationRecord
  belongs_to :site
  validates :status, inclusion: { in: %w[queued running complete partial failed] }
  validates :host, presence: true
  validates :trigger_kind, inclusion: { in: %w[manual weekly] }

  def self.request!(site:, weekly: false)
    created = false
    audit = site.with_lock do
      next if weekly && !site.weekly_site_audit_enabled?
      recent = where(site: site, host: site.host).order(created_at: :desc, id: :desc).first
      next recent if weekly && recent && recent.created_at > 7.days.ago
      next recent if recent && (%w[queued running].include?(recent.status) || recent.finished_at&.after?(5.minutes.ago))
      # A renamed site can have a receipt from a previous hostname.
      active = where(site: site, status: %w[queued running]).first
      next active if active
      created = true
      create!(site: site, host: site.host, trigger_kind: weekly ? "weekly" : "manual")
    end
    SiteAuditJob.perform_later(audit.id) if created
    audit
  end
end
