class ProspectAudit < ApplicationRecord
  DAILY_LIMIT = 3
  WEBSITE_STATES = %w[queued running complete partial failed].freeze
  PROVIDER_STATES = %w[off queued submitting pending complete failed unconfirmed].freeze

  belongs_to :site
  belongs_to :requested_by, class_name: "User", optional: true
  validates :target_host, format: { with: Site::HOST_FORMAT }
  validates :business_name, :market, :keyword, presence: true, length: { maximum: 120 },
    format: { without: /[<>[:cntrl:]]|[\w.+-]+@[\w.-]+\.[a-z]{2,}/i }
  validates :website_status, inclusion: { in: WEBSITE_STATES }
  validates :provider_status, inclusion: { in: PROVIDER_STATES }
  validate :paid_provider_enabled, on: :create

  normalizes :target_host, with: ->(value) { Site.normalize_hostname(value) }
  normalizes :business_name, :market, :keyword, with: ->(value) { value.strip }
  self.filter_attributes += [:provider_job_id]

  def self.request_for(site:, user:, attributes:, provider:)
    now = Time.current
    day = now.in_time_zone(site.time_zone).to_date
    site.with_lock do
      daily = site.prospect_audits.where(site_host: site.host, requested_on: day)
      audit = daily.build(attributes.merge(requested_by: user, provider_status: provider ? "queued" : "off"))
      identity = audit.slice(:target_host, :business_name, :market, :keyword)
      existing = daily.find_by(identity)
      if existing
        if provider && existing.provider_status == "off"
          unless provider_enabled?(site) && !daily.where.not(provider_status: "off").exists?
            audit.errors.add(:base, "Provider collection is unavailable or already reserved for this site today.")
            return audit
          end
          existing.update!(provider_status: "queued", requested_by: user)
        end
        return existing
      end

      if daily.count >= DAILY_LIMIT
        audit.errors.add(:base, "This site has reached its daily limit of #{DAILY_LIMIT} prospect audits.")
      elsif provider && daily.where.not(provider_status: "off").exists?
        audit.errors.add(:base, "This site has already reserved its provider lookup for today.")
      else
        audit.save!
      end
      audit
    end
  end

  def authorised?
    site.host == site_host && Membership.exists?(workspace_id: site.workspace_id, user_id: requested_by_id, role: "owner")
  end

  def self.provider_enabled?(site)
    ENV["LOCALSEODATA_API_KEY"].present? && ENV["LOCALSEODATA_SITE_ID"] == site.id.to_s &&
      ENV["LOCALSEODATA_SITE_HOST"] == site.host &&
      ENV["LOCALSEODATA_ALLOWED_TASKS"].to_s.split(",").map(&:strip).include?("P1")
  end

  private

  def paid_provider_enabled
    if provider_status == "queued" && !self.class.provider_enabled?(site)
      errors.add(:base, "Provider collection is disabled for this site.")
    end
  end
end
