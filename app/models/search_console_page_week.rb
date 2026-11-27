class SearchConsolePageWeek < ApplicationRecord
  belongs_to :site

  DEVICES = %w[desktop mobile].freeze
  validates :device, inclusion: {in: DEVICES}
  validates :property, :query, :week_start, :country, presence: true
end
