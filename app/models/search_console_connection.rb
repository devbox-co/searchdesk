class SearchConsoleConnection < ApplicationRecord
  scope :due_for_sync, -> {
    where(status: %w[connected delayed]).where.not(property: nil)
      .where("synced_at IS NULL OR synced_at <= ?", 24.hours.ago)
      .where("sync_started_at IS NULL OR sync_started_at <= ?", 1.hour.ago)
  }
  belongs_to :site
  has_many :search_console_reports, dependent: :delete_all
  before_update :reset_competing_pages, if: -> { will_save_change_to_property? || will_save_change_to_ai_grant_revision? }
  before_destroy :clear_competing_pages
  encrypts :access_token, :refresh_token
  self.filter_attributes += [:access_token, :refresh_token]

  private

  def reset_competing_pages
    clear_competing_pages
    self.page_week_sync_key = self.page_week_attempted_at = self.page_week_synced_at = self.page_week_error = nil
  end

  def clear_competing_pages
    SearchConsolePageWeek.where(site_id: site_id).delete_all
    SiteFinding.where(site_id: site_id, kind: "competing_pages").delete_all
  end
end
