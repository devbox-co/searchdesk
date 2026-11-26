require "uri"

class Site < ApplicationRecord
  belongs_to :workspace
  has_many :site_audits, dependent: :delete_all
  has_one :ai_setting, dependent: :destroy
  has_many :ai_runs, dependent: :delete_all
  has_many :source_snapshots, dependent: :delete_all
  has_many :project_tasks, dependent: :delete_all
  has_many :keywords, dependent: :destroy
  has_one :search_console_connection, dependent: :destroy
  has_one :local_falcon_connection, dependent: :destroy
  has_one :analytics_connection, dependent: :destroy
  has_many :site_report_links, dependent: :destroy

  TRACKING_MODES = %w[manual demo dataforseo].freeze
  HOST_FORMAT = /\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/

  normalizes :host, with: ->(input) { normalize_hostname(input) }
  validates :name, :location, presence: true, length: { maximum: 160 }
  validates :host, presence: true, uniqueness: { scope: :workspace_id },
    format: { with: HOST_FORMAT, message: "must be a domain such as example.com" }
  validates :language, format: { with: /\A[a-z]{2,3}(?:-[A-Za-z]{2,4})?\z/, message: "must be a language code, such as en" }
  validates :tracking_mode, inclusion: { in: TRACKING_MODES }
  validate :recognized_time_zone

  def self.normalize_hostname(input)
    value = input.to_s.strip.downcase
    uri = URI.parse(value.match?(%r{\Ahttps?://}) ? value : "https://#{value}")
    return value if uri.userinfo || uri.host.blank? || !["", "/"].include?(uri.path) || uri.query || uri.fragment || uri.port != uri.default_port

    uri.host.delete_suffix(".")
  rescue URI::InvalidURIError, URI::InvalidComponentError
    value
  end

  private

  def recognized_time_zone
    errors.add(:time_zone, "must be a recognised time zone") unless ActiveSupport::TimeZone[time_zone.to_s]
  end
end
