class Keyword < ApplicationRecord
  belongs_to :site
  has_many :tracking_series, class_name: "TrackingSeries", dependent: :destroy

  has_many :keyword_page_assignments, dependent: :destroy
  after_save :record_page_assignment, if: :saved_change_to_preferred_url?

  validates :phrase, presence: true, length: { maximum: 200 }, uniqueness: { scope: :site_id }
  normalizes :phrase, with: ->(value) { value.to_s.strip }
  def preferred_page_on(day)
    keyword_page_assignments.where(effective_on: ..day).order(effective_on: :desc).limit(1).pick(:url)
  end

  private

  def record_page_assignment
    today = Time.current.in_time_zone(site.time_zone).to_date
    effective = site.tracking_mode == "demo" && keyword_page_assignments.empty? ? today - 6 : today
    keyword_page_assignments.find_or_initialize_by(effective_on: effective).update!(url: preferred_url)
  end
end
