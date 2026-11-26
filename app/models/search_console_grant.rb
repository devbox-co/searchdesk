class SearchConsoleGrant < ApplicationRecord
  belongs_to :site
  belongs_to :user
  encrypts :verifier
  self.filter_attributes += [:verifier, :state_digest]
end
