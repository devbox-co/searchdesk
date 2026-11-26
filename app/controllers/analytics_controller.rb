class AnalyticsController < ApplicationController
  before_action :require_workspace_owner, except: :show
  rescue_from Analytics::Client::Error, with: :provider_error

  def show
    @connection = current_site.analytics_connection
    @configured = Analytics::Client.configured?
  end

  def authorize
    return redirect_to(analytics_path, alert: "Google sign-in has not been configured.") unless Analytics::Client.configured?
    state = SecureRandom.urlsafe_base64(32)
    verifier = SecureRandom.urlsafe_base64(64)
    url = Analytics::Client.authorization_url(state: state, verifier: verifier)
    digest = Digest::SHA256.hexdigest(state)
    current_site.with_lock do
      AnalyticsGrant.where(site: current_site, user: current_user).delete_all
      AnalyticsGrant.create!(site: current_site, user: current_user, state_digest: digest, verifier: verifier, expires_at: 10.minutes.from_now)
    end
    session[:analytics_flow] = digest
    redirect_to url, allow_other_host: true, status: :see_other
  end

  def callback
    state = params[:state].to_s
    digest = Digest::SHA256.hexdigest(state)
    expected = session.delete(:analytics_flow).to_s
    unless state.present? && ActiveSupport::SecurityUtils.secure_compare(expected, digest)
      return redirect_to(analytics_path, alert: "The Analytics authorisation has expired. Start again.")
    end
    grant = AnalyticsGrant.transaction do
      flow = AnalyticsGrant.lock.find_by(site: current_site, user: current_user, state_digest: digest)
      next unless flow&.expires_at&.future?
      flow.update!(state_digest: Digest::SHA256.hexdigest(SecureRandom.hex(32)))
      flow
    end
    return redirect_to(analytics_path, alert: "The Analytics authorisation has expired. Start again.") unless grant
    return redirect_to(analytics_path, alert: "Google Analytics access was not granted.") if params[:error].present? || params[:code].blank?

    tokens = Analytics::Client.new.exchange(code: params[:code], verifier: grant.verifier)
    unless Analytics::Client.readonly_scope?(tokens["scope"]) && tokens["refresh_token"].present?
      return redirect_to(analytics_path, alert: "A separate offline grant limited to read-only Google Analytics access is required.")
    end
    accepted = current_site.with_lock do
      claim = AnalyticsGrant.lock.find_by(id: grant.id, state_digest: grant.state_digest)
      next false unless claim&.expires_at&.future? && owner_still_authorized?
      connection = current_site.analytics_connection || current_site.build_analytics_connection
      connection.update!(access_token: tokens.fetch("access_token"), refresh_token: tokens.fetch("refresh_token"), grant_key: SecureRandom.uuid,
        token_expires_at: Time.current + tokens.fetch("expires_in").to_i.seconds, status: "choose_property", last_error: nil,
        property_id: nil, property_name: nil, property_zone: nil, verified_host: nil, stream_ids: [], sync_key: nil, sync_started_at: nil, synced_at: nil, report: {})
    end
    redirect_to analytics_path, **(accepted ? { notice: "Google Analytics authorised. Enter the property you want to use." } : { alert: "The connection changed. Start again." })
  ensure
    AnalyticsGrant.where(id: grant.id, state_digest: grant.state_digest).delete_all if grant
  end

  def update
    return redirect_to(analytics_path, alert: "Google sign-in has not been configured.") unless Analytics::Client.configured?
    connection = current_site.analytics_connection
    return redirect_to(analytics_path, alert: "Connect Google Analytics first.") unless connection
    id = Analytics::Client.property_id(params[:property])
    return redirect_to(analytics_path, alert: "Enter the numeric GA4 property ID shown in Admin → Property details.") unless id
    client = Analytics::Client.new
    grant_key = connection.grant_key
    host = current_site.host
    token = connection.token_for!(client, expected_grant: grant_key)
    binding = client.binding(token: token, property: id, host: host)
    accepted = current_site.with_lock do
      next false unless owner_still_authorized? && current_site.host == host
      connection.with_lock do
        next false unless connection.grant_key == grant_key && connection.status != "reconnect"
        if connection.property_id != id || connection.verified_host != host
          connection.assign_attributes(report: {}, synced_at: nil, sync_started_at: nil, sync_key: nil)
        end
        connection.update!(binding.merge(status: "connected", last_error: nil))
      end
    end
    return redirect_to(analytics_path, alert: "The connection changed. Reload and try again.") unless accepted
    AnalyticsSyncJob.perform_later(connection.id)
    redirect_to analytics_path, notice: "Property and web stream verified. Your first report is queued."
  end

  def sync
    connection = current_site.analytics_connection
    if Analytics::Client.configured? && connection&.property_id && %w[connected delayed].include?(connection.status)
      AnalyticsSyncJob.perform_later(connection.id)
      redirect_to analytics_path, notice: "Analytics report queued."
    else
      redirect_to analytics_path, alert: "Connect Google Analytics and choose a verified property first."
    end
  end

  def destroy
    current_site.with_lock do
      AnalyticsGrant.where(site: current_site).delete_all
      current_site.analytics_connection&.destroy!
    end
    session.delete(:analytics_flow)
    redirect_to analytics_path, notice: "Analytics disconnected. Dated reports already imported are available in Evidence."
  end

  private

  def owner_still_authorized?
    current_site.workspace.memberships.exists?(user: current_user, role: "owner")
  end

  def provider_error(error)
    redirect_to analytics_path, alert: error.message
  end
end
