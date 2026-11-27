class SiteFinding < ApplicationRecord
  belongs_to :site
  belongs_to :keyword, optional: true

  DISPOSITIONS = %w[open monitor accepted_overlap].freeze
  validates :kind, :fingerprint, presence: true
  validates :level, inclusion: {in: %w[review watch limited]}
  validates :disposition, inclusion: {in: DISPOSITIONS}
  validate :keyword_belongs_to_site

  scope :competing_pages, -> { where(kind: "competing_pages") }
  scope :current, -> { where(active: true) }

  def self.for_current_search_scope(site)
    connection = site.search_console_connection
    country = SearchConsole::DailyPositions.country_for(site)
    return none unless country && SearchConsole::Client.matches?(connection&.property, site.host)
    return none unless %w[connected delayed reconnect].include?(connection.status)

    current.competing_pages.where(site: site, keyword: site.keywords)
      .where("evidence->>'property' = ? AND evidence->>'country' = ?", connection.property, country)
  end

  private

  def keyword_belongs_to_site
    errors.add(:keyword, "must belong to the same site") if keyword && keyword.site_id != site_id
  end
end
