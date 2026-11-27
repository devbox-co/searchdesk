class RankObservation < ApplicationRecord
  belongs_to :daily_slot
  delegate :day, :tracking_series, to: :daily_slot
  scope :comparable, -> { where(status: %w[ranked outside]) }

  def self.provider_for(site)
    joins(daily_slot: { tracking_series: :keyword }).where(keywords: { site_id: site.id },
      tracking_series: { source: "dataforseo" }, rank_observations: { source: "dataforseo" })
      .where("tracking_series.settings->>'host' = ?", site.host)
  end
end
