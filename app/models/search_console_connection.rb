class SearchConsoleConnection < ApplicationRecord
  scope :due_for_sync, -> {
    where(status: %w[connected delayed]).where.not(property: nil)
      .where("synced_at IS NULL OR synced_at <= ?", 24.hours.ago)
      .where("sync_started_at IS NULL OR sync_started_at <= ?", 1.hour.ago)
  }
  belongs_to :site
  has_many :search_console_reports, dependent: :delete_all
  encrypts :access_token, :refresh_token
  self.filter_attributes += [:access_token, :refresh_token]
end
