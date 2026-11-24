class LocalFalconConnection < ApplicationRecord
  belongs_to :site
  encrypts :verifier, :access_token, :refresh_token
  self.filter_attributes += %i[verifier access_token refresh_token state_digest]
  validates :place_id, format: { with: /\A[A-Za-z0-9_-]{12,180}\z/ }, allow_nil: true
  scope :due, -> {
    where(status: %w[connected delayed]).where("synced_at IS NULL OR synced_at < ?", 23.hours.ago)
      .where("last_attempt_at IS NULL OR last_attempt_at < ?", 1.hour.ago)
  }
end
