class AiSetting < ApplicationRecord
  belongs_to :site
  FIELD_LIMIT = 800
  PROFILE = %w[services priorities enquiry_definition].freeze
  SOURCES = %w[share_google share_semrush share_maps].freeze
  validates(*PROFILE, length: { maximum: FIELD_LIMIT })
  self.filter_attributes += PROFILE
  validate :profile_contains_no_contact_or_secret
  before_validation :update_revision
  after_update_commit :purge_withdrawn_evidence

  def may_ask?(user:)
    return false unless enabled? && user
    role = Membership.where(workspace_id: site.workspace_id, user_id: user.id).pick(:role)
    role == "owner" || (role == "manager" && managers_enabled?)
  end

  private

  def update_revision
    self.revision = SecureRandom.uuid if new_record? || (changed & (PROFILE + SOURCES + %w[enabled managers_enabled daily_brief_enabled])).any?
  end

  def profile_contains_no_contact_or_secret
    PROFILE.each do |field|
      if self[field].to_s.match?(/\b(?:sk-(?:proj-|admin-)?[\w-]{8,}|bearer\s+\S+|[\w.+-]+@[\w.-]+\.[a-z]{2,})\b/i)
        errors.add(field, "must contain public business information only")
      end
    end
  end

  def purge_withdrawn_evidence
    if saved_change_to_enabled? && !enabled?
      AiRun.erase_history!(site: site)
    elsif SOURCES.any? { |field| saved_change_to_attribute?(field) && !self[field] }
      AiRun.purge_hidden_for!(site: site, setting: self)
    end
  end
end
