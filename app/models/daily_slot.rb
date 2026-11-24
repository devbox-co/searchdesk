class DailySlot < ApplicationRecord
  belongs_to :tracking_series
  has_one :rank_observation, dependent: :destroy
  validates :day, presence: true
end
