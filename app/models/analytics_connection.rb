class AnalyticsConnection < ApplicationRecord
  belongs_to :site
  encrypts :access_token, :refresh_token
  self.filter_attributes += [:access_token, :refresh_token, :grant_key, :sync_key]

  scope :due_for_sync, -> {
    where(status: %w[connected delayed]).where.not(property_id: nil)
      .where("synced_at IS NULL OR synced_at <= ?", 24.hours.ago)
      .where("sync_started_at IS NULL OR sync_started_at <= ?", 1.hour.ago)
  }

  def token_for!(client, expected_grant:)
    with_lock do
      raise Analytics::Client::AccessError, "The Analytics connection changed. Reopen the connection to continue." if grant_key != expected_grant || status == "reconnect"
      return access_token if access_token.present? && token_expires_at && token_expires_at > 2.minutes.from_now

      grant = client.refresh(refresh_token)
      if grant.key?("scope") && !Analytics::Client.readonly_scope?(grant["scope"])
        raise Analytics::Client::AccessError, "Reconnect with only read-only Google Analytics access."
      end
      update!(access_token: grant.fetch("access_token"), token_expires_at: Time.current + grant.fetch("expires_in").to_i.seconds,
              refresh_token: grant["refresh_token"].presence || refresh_token)
      access_token
    end
  end
end
