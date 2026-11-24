class WorkspaceMembersController < ApplicationController
  skip_before_action :require_site
  before_action :require_workspace_owner
  before_action :load_changeable_membership, only: %i[update destroy]

  def index
    @memberships = current_workspace.memberships.includes(:user).order(:id)
  end

  def create
    attributes = params.require(:membership).permit(:email, :role)
    user = User.find_by(email: attributes[:email].to_s)
    if user&.email_verified_at && Membership::ASSIGNABLE_ROLES.include?(attributes[:role])
      membership = current_workspace.memberships.build(user: user, role: attributes[:role])
      return redirect_to workspace_members_path, notice: "Workspace access added." if membership.save
    end
    redirect_to workspace_members_path, alert: "Ask the person to verify their registered email, then choose manager or viewer. Existing members appear below."
  rescue ActiveRecord::RecordNotUnique
    redirect_to workspace_members_path, alert: "This account already has access."
  end

  def update
    role = params.require(:membership).permit(:role)[:role]
    if Membership::ASSIGNABLE_ROLES.include?(role) && @membership.update(role: role)
      redirect_to workspace_members_path, notice: "Workspace role updated."
    else
      redirect_to workspace_members_path, alert: "Choose manager or viewer."
    end
  end

  def destroy
    @membership.destroy!
    redirect_to workspace_members_path, notice: "Workspace access removed."
  end

  private

  def load_changeable_membership
    @membership = current_workspace.memberships.find(params[:id])
    head :forbidden if @membership.owner?
  end
end
