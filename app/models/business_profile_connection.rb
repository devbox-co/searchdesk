class BusinessProfileConnection < ApplicationRecord
  belongs_to :site
  encrypts :refresh_token
  self.filter_attributes += [:refresh_token, :grant_revision]

  def self.allowed_for?(site)
    GoogleBusiness::Client.configured? && ENV["SEARCHDESK_GBP_WORKSPACE_ID"] == site.workspace_id.to_s
  end

  def connected? = account_id.present? && location_id.present? && site.host == site_host && self.class.allowed_for?(site)

  def parent
    "accounts/#{account_id}/locations/#{location_id}"
  end

  def access_token!(client)
    data = client.token(refresh_token)
    rotated = data["refresh_token"]
    update!(refresh_token: rotated) if rotated.present? && rotated != refresh_token
    data.fetch("access_token")
  end
end
