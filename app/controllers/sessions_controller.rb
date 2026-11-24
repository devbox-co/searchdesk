class SessionsController < ApplicationController
  skip_before_action :require_authentication, only: %i[new create]
  skip_before_action :require_site
  rate_limit to: 15, within: 5.minutes, only: :create

  def new
    redirect_to dashboard_path if current_user
  end

  def create
    credentials = params.require(:session).permit(:email, :password)
    user = User.authenticate_by(email: credentials[:email].to_s, password: credentials[:password].to_s)
    if user
      start_session_for(user)
      redirect_to dashboard_path
    else
      flash.now[:alert] = "Check your email and password and try again."
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    active_login_session&.destroy!
    reset_session
    redirect_to login_path, notice: "Signed out."
  end
end
