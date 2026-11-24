class Membership < ApplicationRecord
  belongs_to :user
  belongs_to :workspace

  ROLES = %w[owner manager viewer].freeze
  ASSIGNABLE_ROLES = %w[manager viewer].freeze
  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :workspace_id }

  def owner?
    role == "owner"
  end

  def can_manage_site?
    owner? || role == "manager"
  end
end
