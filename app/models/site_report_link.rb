require "uri"

class SiteReportLink < ApplicationRecord
  LOCAL_FALCON_HOSTS = %w[app.localfalcon.com localfalcon.com www.localfalcon.com].freeze
  REPORT_PATH = %r{\A/reports/view/[a-zA-Z0-9_-]+/?\z}

  belongs_to :site
  validates :provider, inclusion: { in: ["local-falcon"] }
  validates :url, presence: true, length: { maximum: 512 }
  validate :valid_report_url

  private

  def valid_report_url
    uri = URI.parse(url.to_s)
    return if uri.is_a?(URI::HTTPS) && uri.userinfo.nil? && uri.port == 443 &&
              LOCAL_FALCON_HOSTS.include?(uri.host.to_s.downcase) &&
              REPORT_PATH.match?(uri.path.to_s) && uri.query.nil? && uri.fragment.nil?

    errors.add(:url, "must be a direct HTTPS Local Falcon report link such as https://app.localfalcon.com/reports/view/REPORT_ID")
  rescue URI::InvalidURIError
    errors.add(:url, "must be a valid Local Falcon report URL")
  end
end
