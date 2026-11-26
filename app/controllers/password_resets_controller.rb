class PasswordResetsController < ApplicationController
  skip_before_action :require_authentication, :require_site
  before_action :load_user_from_token, only: %i[edit update]
  rate_limit to: 8, within: 15.minutes, only: :create

  def new
  end

  def create
    user = User.find_by(email: params.dig(:password_reset, :email).to_s)
    PasswordResetMailer.instructions(user).deliver_later if user
    redirect_to login_path, notice: "If that address has an account, we’ll send password reset instructions."
  end

  def edit
  end

  def update
    credentials = params.require(:user).permit(:password, :password_confirmation)
    if credentials[:password].blank?
      @user.errors.add(:password, "must be at least 12 characters")
      return render :edit, status: :unprocessable_entity
    end

    @user.with_lock do
      return invalid_token unless User.find_by_password_reset_token(@token)
      if @user.update(credentials)
        reset_session
        redirect_to login_path, notice: "Password changed. Sign in with your new password."
      else
        render :edit, status: :unprocessable_entity
      end
    end
  end

  private

  def load_user_from_token
    @token = params[:token].to_s
    @user = User.find_by_password_reset_token(@token)
    invalid_token unless @user
  end

  def invalid_token
    redirect_to new_password_reset_path, alert: "This reset link has expired or has already been used."
  end
end
