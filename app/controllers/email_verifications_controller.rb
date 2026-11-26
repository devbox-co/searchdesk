class EmailVerificationsController < ApplicationController
  skip_before_action :require_site
  before_action :verify_recipient, only: %i[show confirm]
  rate_limit to: 5, within: 30.minutes, only: :create

  def new
  end

  def create
    if current_user.email_verified_at
      redirect_to new_email_verification_path, notice: "Your email is verified."
    else
      EmailVerificationMailer.instructions(current_user).deliver_later
      redirect_to new_email_verification_path, notice: "Check your email for the verification link."
    end
  end

  def show
  end

  def confirm
    current_user.update!(email_verified_at: Time.current)
    redirect_to dashboard_path, notice: "Your email has been verified."
  end

  private

  def verify_recipient
    @token = params[:token].to_s
    user = User.find_by_token_for(:email_verification, @token)
    return if user && user.id == current_user.id

    redirect_to new_email_verification_path, alert: "Sign in to the matching account and request a new verification link."
  end
end
