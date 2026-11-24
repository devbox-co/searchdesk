require "uri"

class SourceSnapshot < ApplicationRecord
  belongs_to :site
  validates :external_id, :provider, :title, :observed_on, :scope, presence: true
  validates :external_id, :provider, :title, :keyword, length: { maximum: 255 }
  validates :scope, length: { maximum: 10_000 }
  validates :source_path, :source_url, length: { maximum: 4096 }
  validate :valid_source_url
  validate :valid_metrics

  GBP_CACHE_ID = "local-falcon-linked-gbp-current"
  scope :linked_gbp_cache, -> { where(provider: "Google Business Profile", external_id: GBP_CACHE_ID, source_path: nil) }

  REPORT_IMPORT_PROVIDERS = %w[gsc ga4 semrush].freeze
  scope :catalogue_imports, -> {
    where(provider: REPORT_IMPORT_PROVIDERS).where(
      "NOT (provider = 'gsc' AND COALESCE(metrics->>'source_basis', '') = 'final_api')"
    )
  }

  # A new OAuth grant must select a verified property before earlier API readings
  # for that property appear again. Owner-imported archive files remain independent.
  def self.visible_for(site)
    property = site.search_console_connection&.property.to_s
    visible = site.source_snapshots.where.not(id: linked_gbp_cache.where(updated_at: ..29.days.ago).select(:id))
    visible.where(<<~SQL.squish, property)
      NOT (provider = 'gsc' AND external_id LIKE 'daily-position-%'
        AND COALESCE(metrics->>'source_basis', '') = 'final_api')
      OR metrics->>'property' = ?
    SQL
  end

  private

  def valid_source_url
    return if source_url.blank?
    url = URI.parse(source_url)
    return if url.is_a?(URI::HTTP) && url.host.present? && url.userinfo.nil? && !source_url.include?("\\")
    errors.add(:source_url, "must be an HTTP or HTTPS link without account credentials")
  rescue URI::Error
    errors.add(:source_url, "must be a valid URL")
  end

  def valid_metrics
    unless metrics.is_a?(Hash) && metrics.to_json.bytesize <= 128.kilobytes
      errors.add(:metrics, "must be a JSON object up to 128 KiB")
    end
  end
end
