class SeoWorkflowRun < ApplicationRecord
  belongs_to :site
  has_one :report_delivery, class_name: "SeoWorkflowReportDelivery", dependent: :delete
  belongs_to :reviewed_by, class_name: "User", optional: true
  belongs_to :delivered_by, class_name: "User", optional: true

  after_save :record_notification, if: :saved_change_to_status?

  REVIEW_WINDOW = 72.hours
  REVIEW_TRANSITIONS = { "approve" => "approved", "reject" => "rejected" }.freeze

  scope :pending_review, ->(now) { where(status: "awaiting_approval").where("updated_at > ?", now - REVIEW_WINDOW) }
  scope :latest_by_template, -> {
    select("DISTINCT ON (template_key) seo_workflow_runs.*").order(:template_key, period_on: :desc, id: :desc)
  }

  def self.generate!(site:, template:, day:, now: Time.current)
    raise ArgumentError, "Template is unavailable" unless template.available?

    identity = { template_key: template.key, period_on: day, site_host: site.host }
    record = site.seo_workflow_runs.find_by(identity) || site.seo_workflow_runs.create_or_find_by!(identity) do |run|
      run.assign_attributes(report_attributes(site: site, template: template, day: day, now: now))
    end
    if record.status == "missing_evidence"
      record.with_lock do
        next unless record.status == "missing_evidence" && record.site_host == site.host

        attributes = report_attributes(site: site, template: template, day: day, now: now)
        record.update!(attributes) unless attributes[:result].empty?
      end
    end
    record
  end

  def self.report_attributes(site:, template:, day:, now:)
    result = SeoWorkflows::Report.new(site: site, template: template, day: day, now: now).rows
    status = if result.empty?
      "missing_evidence"
    elsif template.tier == :autonomous
      "complete"
    else
      "awaiting_approval"
    end
    { result: result, status: status }
  end
  private_class_method :report_attributes

  def refresh_weekly_report!(now: Time.current)
    with_lock do
      next unless template_key == "R1" && status == "complete" && site.reload.host == site_host

      rows = SeoWorkflows::Report.new(site: site, template: template, day: period_on, now: now).rows
      update!(result: rows) if rows.any? && result != rows
    end
  end

  def refresh_rollup!(now: Time.current)
    with_lock do
      next unless template_key == "R3" && site.reload.host == site_host

      rows = SeoWorkflows::Rollup.new(site: site, day: period_on, now: now).rows
      update!(result: rows, status: rows.empty? ? "missing_evidence" : "complete") if result != rows
    end
  end

  def template = SeoWorkflows::Catalogue.fetch(template_key)

  def review_deadline = updated_at + REVIEW_WINDOW

  def effective_status(now: Time.current)
    if status == "awaiting_approval" && review_deadline <= now
      "expired"
    else
      status
    end
  end

  def landing_page_draft? = template_key == "E4"

  def draft_revision
    Digest::SHA256.hexdigest(result.to_json) if landing_page_draft?
  end

  def refresh_landing_page_draft!(user:, now: Time.current)
    with_lock do
      next false unless landing_page_draft? && effective_status(now: now) == "awaiting_approval" && authorised_owner?(user)

      refreshed = SeoWorkflows::Report.new(site: site.reload, template: template, day: period_on, now: now).rows
      next false if refreshed.empty? || refreshed == result

      update!(result: refreshed)
    end
  end

  def review!(decision:, user:, revision: nil, now: Time.current)
    with_lock do
      next false unless REVIEW_TRANSITIONS.key?(decision) && effective_status(now: now) == "awaiting_approval"
      next false unless authorised_owner?(user)
      next false if landing_page_draft? && revision != draft_revision

      update!(status: REVIEW_TRANSITIONS.fetch(decision), reviewed_by: user, reviewed_at: now)
    end
  end

  def record_delivery!(user:, now: Time.current)
    with_lock do
      next false unless approved_for_delivery_by?(user) && !report_delivery

      update!(status: "delivered", delivered_by: user, delivered_at: now)
    end
  end

  def approved_for_delivery_by?(user)
    template.tier == :notify && status == "approved" && authorised_owner?(user)
  end

  def check_review_window!(now: Time.current)
    with_lock do
      next unless status == "awaiting_approval" && site.host == site_host

      if effective_status(now: now) == "expired"
        update!(status: "expired")
      elsif updated_at + 48.hours <= now
        SeoWorkflowNotification.record!(run: self, kind: "reminder")
      end
    end
  end

  private

  def record_notification
    return unless SeoWorkflowNotification::MESSAGES.key?(status)

    kind = status == "complete" && result.any? { |row| row["attention"] == true } ? "attention" : status
    SeoWorkflowNotification.record!(run: self, kind: kind)
  end

  def authorised_owner?(user)
    current_site = Site.find(site_id)
    current_site.host == site_host && Membership.exists?(workspace_id: current_site.workspace_id, user: user, role: "owner")
  end
end
