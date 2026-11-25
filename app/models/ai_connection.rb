class AiConnection < ApplicationRecord
  belongs_to :workspace
  encrypts :api_key
  self.filter_attributes += [:api_key]
  validates :monthly_budget_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 99_999_999 }
  validates :project_label, length: { maximum: 120 }
  validates :status, inclusion: { in: %w[untested ready reconnect credits_exhausted] }
  validate :project_key_format
  before_validation :update_credential_revision

  def self.owner_controlled_installation?
    ENV.fetch("SEARCHDESK_OWNER_CONTROLLED_AI", Rails.env.test? ? "true" : "false") == "true"
  end

  def configured?
    self.class.owner_controlled_installation? && api_key.present?
  end

  def month_spend_microusd(now: Time.current)
    start = now.utc.beginning_of_month
    AiRun.joins(:site).where(sites: { workspace_id: workspace_id }, attempted_at: start...start.next_month)
      .sum(Arel.sql("COALESCE(ai_runs.actual_microusd, ai_runs.reserved_microusd)"))
  end

  def disconnect!
    with_lock do
      update!(api_key: nil, status: "untested", last_verified_at: nil, monthly_budget_cents: 0)
      AiSetting.where(site_id: workspace.sites.select(:id), daily_brief_enabled: true).find_each do |setting|
        setting.update!(daily_brief_enabled: false)
      end
    end
  end

  private

  def update_credential_revision
    return unless new_record? || will_save_change_to_api_key?
    self.revision = SecureRandom.uuid
    if persisted?
      self.status = "untested"
      self.last_verified_at = nil
    end
  end

  def project_key_format
    return if api_key.nil?
    unless api_key.match?(/\Ask-[A-Za-z0-9_-]{4,510}\z/) && !api_key.start_with?("sk-admin-")
      errors.add(:api_key, "must be an OpenAI API project key")
    end
  end
end
