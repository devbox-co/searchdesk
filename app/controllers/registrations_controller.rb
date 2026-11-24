class RegistrationsController < ApplicationController
  skip_before_action :require_authentication, :require_site
  rate_limit to: 10, within: 15.minutes, only: :create

  def new
    @user = User.new
  end

  def create
    @user = User.new(params.require(:user).permit(:email, :password, :password_confirmation))
    workspace_name = params.dig(:workspace, :name).to_s.strip.presence || "My workspace"

    User.transaction do
      @user.save!
      workspace = Workspace.create!(name: workspace_name)
      workspace.memberships.create!(user: @user, role: "owner")
    end
    start_session_for(@user)
    redirect_to onboarding_path
  rescue ActiveRecord::RecordInvalid => error
    @user.errors.add(:base, error.record.errors.full_messages.to_sentence) unless error.record == @user
    render :new, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotUnique
    @user.errors.add(:email, "has already been taken")
    render :new, status: :unprocessable_entity
  end
end
