class RankObservation < ApplicationRecord
  belongs_to :daily_slot
  delegate :day, :tracking_series, to: :daily_slot
  scope :comparable, -> { where(status: %w[ranked outside]) }
end
