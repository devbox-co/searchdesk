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

  private

  def keyword_belongs_to_site
    errors.add(:keyword, "must belong to the same site") if keyword && keyword.site_id != site_id
  end
end
