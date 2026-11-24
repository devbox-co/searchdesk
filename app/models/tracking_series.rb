class TrackingSeries < ApplicationRecord
  belongs_to :keyword
  belongs_to :baseline_observation, class_name: "RankObservation", optional: true
  has_many :daily_slots, dependent: :destroy
  has_many :rank_observations, through: :daily_slots
  has_many :keyword_actions, dependent: :destroy
  delegate :site, to: :keyword

  scope :current, -> { where(archived_at: nil) }
  validates :device, inclusion: { in: %w[desktop mobile] }
  validates :source, inclusion: { in: %w[demo manual dataforseo] }
  attr_readonly :keyword_id, :device, :source, :fingerprint, :settings, :enrolled_on

  def date_in_zone(time = Time.current)
    time.in_time_zone(settings.fetch("time_zone")).to_date
  end
end
