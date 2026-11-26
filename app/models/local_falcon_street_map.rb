class LocalFalconStreetMap < ApplicationRecord
  belongs_to :source_snapshot
  self.filter_attributes += [:png]
end
