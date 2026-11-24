module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication, :require_site
    helper_method :current_user, :current_workspace, :current_membership, :current_site,
      :available_sites, :workspace_owner?, :can_manage_site?
  end

  private

  def current_user
    return @current_user if defined?(@current_user)
    user = active_login_session&.user
    @current_user = user if user && user.session_version == session[:session_version]
  end

  def active_login_session
    return @active_login_session if defined?(@active_login_session)
    @active_login_session = LoginSession.active.includes(:user).find_by(id: session[:login_session_id]) if session[:login_session_id]
  end

  def current_membership
    return @current_membership if defined?(@current_membership)
    memberships = current_user&.memberships
    @current_membership = if session[:workspace_id]
      memberships&.find_by(workspace_id: session[:workspace_id])
    else
      memberships&.order(:id)&.first
    end
  end

  def current_workspace
    current_membership&.workspace
  end

  def available_sites
    return Site.none unless current_user

    Site.where(workspace_id: current_user.memberships.select(:workspace_id)).order(:name, :id)
  end

  def current_site
    return @current_site if defined?(@current_site)
    @current_site = if session[:site_id]
      current_workspace&.sites&.find_by(id: session[:site_id])
    else
      current_workspace&.sites&.order(:id)&.first
    end
  end

  def workspace_owner?
    current_membership&.owner? == true
  end

  def can_manage_site?
    current_membership&.can_manage_site? == true
  end

  def require_authentication
    unless current_user
      reset_session
      return redirect_to login_path
    end

    # A stale form must never apply to the next accessible workspace or site.
    return if (!session[:workspace_id] || current_membership) && (!session[:site_id] || current_site)
    reset_csrf_token(request)
    session.delete(:workspace_id)
    session.delete(:site_id)
    return head :forbidden unless request.get? || request.head?

    redirect_to dashboard_path, alert: "Your workspace access changed. Check the selected site before continuing."
  end

  def select_current_site(site)
    # Tabs opened before the switch must reload their forms for the new site.
    reset_csrf_token(request) unless session[:site_id] == site.id && session[:workspace_id] == site.workspace_id
    session[:workspace_id] = site.workspace_id
    session[:site_id] = site.id
  end

  def require_site
    redirect_to onboarding_path unless current_site
  end

  def require_site_manager
    head :forbidden unless can_manage_site?
  end

  def require_workspace_owner
    head :forbidden unless workspace_owner?
  end

  def start_session_for(user)
    active_login_session&.destroy!
    reset_session
    user.login_sessions.where(expires_at: ..Time.current).delete_all
    session[:login_session_id] = user.login_sessions.create!(expires_at: 30.days.from_now).id
    session[:session_version] = user.session_version
    membership = user.memberships.joins(workspace: :sites).order(:id).first || user.memberships.order(:id).first
    session[:workspace_id] = membership.workspace_id if membership
  end
end
