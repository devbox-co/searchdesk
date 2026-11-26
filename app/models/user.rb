class User < ApplicationRecord
  has_secure_password reset_token: { expires_in: 20.minutes }
  has_many :memberships, dependent: :destroy
  has_many :login_sessions, dependent: :delete_all
  has_many :workspaces, through: :memberships

  normalizes :email, with: ->(email) { email.strip.downcase }
  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }, length: { maximum: 254 }
  validates :password, length: { minimum: 12 }, allow_nil: true

  generates_token_for :email_verification, expires_in: 24.hours do
    [email, email_verified_at&.to_i, session_version]
  end

  before_update :invalidate_sessions_on_password_change

  private

  def invalidate_sessions_on_password_change
    return unless will_save_change_to_password_digest?

    self.session_version += 1
    login_sessions.delete_all
  end
end
