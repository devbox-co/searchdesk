class KeywordAction < ApplicationRecord
  scope :for_site, ->(site) { joins(tracking_series: :keyword).where(keywords: { site_id: site.id }) }
  belongs_to :tracking_series
  has_many :action_drafts, dependent: :delete_all
  after_save :prepare_review, if: :saved_change_to_evidence?
  delegate :keyword, to: :tracking_series
  validates :status, inclusion: { in: %w[open resolved] }

  private

  def prepare_review
    ActionDraft.capture!(self)
  end
end
