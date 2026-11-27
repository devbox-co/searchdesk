class BusinessProfileController < ApplicationController
  before_action :require_workspace_owner, :require_provider, except: :destroy
  before_action :require_workspace_owner, only: :destroy

  def show
    @connection = current_site.business_profile_connection
    response.headers["Cache-Control"] = "no-store"
  end

  def authorize
    verifier = SecureRandom.urlsafe_base64(48)
    state = SecureRandom.urlsafe_base64(32)
    session[:business_profile_oauth] = {
      "site_id" => current_site.id, "user_id" => current_user.id, "started_at" => Time.current.to_i,
      "state_hash" => Digest::SHA256.hexdigest(state), "verifier" => verifier
    }
    redirect_to GoogleBusiness::Client.authorization_url(state: state, verifier: verifier), allow_other_host: true
  end

  def callback
    oauth = session.delete(:business_profile_oauth)
    unless oauth && oauth["site_id"] == current_site.id && oauth["user_id"] == current_user.id &&
        (0..10.minutes.to_i).cover?(Time.current.to_i - oauth.fetch("started_at")) &&
        ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(params[:state].to_s), oauth.fetch("state_hash")) &&
        params[:code].is_a?(String)
      return redirect_to business_profile_path, alert: "Authorization expired or changed. Start the connection again."
    end

    grant = GoogleBusiness::Client.new.exchange(code: params[:code], verifier: oauth.fetch("verifier"))
    unless grant["scope"].to_s.split.include?(GoogleBusiness::Client::SCOPE) && grant["refresh_token"].present?
      return redirect_to business_profile_path, alert: "Google did not grant Business Profile access."
    end

    current_site.with_lock do
      existing = current_site.business_profile_connection || current_site.build_business_profile_connection
      existing.update!(refresh_token: grant.fetch("refresh_token"), grant_revision: SecureRandom.uuid,
        site_host: current_site.host, account_id: nil, location_id: nil)
    end
    redirect_to business_profile_path, notice: "Google authorised. Choose the specific location."
  rescue GoogleReadOnly::Client::Error
    redirect_to business_profile_path, alert: "Google could not establish the connection."
  end

  def update
    connection = current_site.business_profile_connection
    return head :conflict unless connection && connection.site_host == current_site.host

    account, location = params.values_at(:account_id, :location_id)
    connection.with_lock do
      token = client_token(connection)
      @client.profile(token: token, account_id: account, location_id: location, host: current_site.host)
      connection.update!(account_id: account, location_id: location, grant_revision: SecureRandom.uuid)
    end
    redirect_to business_profile_path, notice: "Business Profile location verified."
  rescue GoogleReadOnly::Client::Error => error
    redirect_to business_profile_path, alert: error.message
  end

  def inspect_live
    @connection = current_site.business_profile_connection
    return head :conflict unless @connection&.connected?

    @connection.with_lock do
      token = client_token(@connection)
      @profile = @client.profile(token: token, account_id: @connection.account_id,
        location_id: @connection.location_id, host: current_site.host)
      @reviews = @client.reviews(token: token, parent: @connection.parent)
    end
    response.headers["Cache-Control"] = "no-store"
    render :show
  rescue GoogleReadOnly::Client::Error => error
    redirect_to business_profile_path, alert: error.message
  end

  def destroy
    current_site.business_profile_connection&.destroy!
    session.delete(:business_profile_oauth)
    redirect_to seo_workflows_path, status: :see_other, notice: "Business Profile disconnected from Searchdesk."
  end

  private

  def client_token(connection)
    @client ||= GoogleBusiness::Client.new
    connection.access_token!(@client)
  end

  def require_provider
    head :forbidden unless BusinessProfileConnection.allowed_for?(current_site)
  end
end
