class Workspace < ApplicationRecord
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :sites, dependent: :destroy
  has_one :ai_connection, dependent: :destroy

  validates :name, presence: true, length: { maximum: 120 }
end
