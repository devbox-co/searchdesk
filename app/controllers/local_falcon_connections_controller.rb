class LocalFalconConnectionsController < ApplicationController
  before_action :require_workspace_owner, except: :show
  rescue_from LocalFalcon::Client::Error do |error|
    redirect_to local_falcon_connection_path, alert: error.message
  end

  def show
    @connection = current_site.local_falcon_connection
    @saved_report = current_site.site_report_links.find_by(provider: "local-falcon")
    @map_scans = LocalFalcon::MapsSummary.latest(current_site)
  end

  def update
    connection = current_site.local_falcon_connection || current_site.build_local_falcon_connection
    return redirect_to(local_falcon_connection_path, alert: "Disconnect this account before changing the location.") if connection.refresh_token.present?
    connection.assign_attributes(place_id: params[:place_id].to_s.strip.presence, state_digest: nil, verifier: nil)
    redirect_to local_falcon_connection_path, connection.save ? { notice: "Location saved for verification with Local Falcon." } : { alert: "Enter a valid Google Place ID." }
  end

  def authorize
    state = SecureRandom.urlsafe_base64(32)
    verifier = SecureRandom.urlsafe_base64(64)
    client = LocalFalcon::Client.new
    callback = LocalFalcon::Client.callback_url
    connection = current_site.with_lock { current_site.local_falcon_connection || current_site.create_local_falcon_connection! }
    unless connection.place_id.present? || LocalFalcon::ReportReader.saved_key(current_site)
      return redirect_to local_falcon_connection_path, alert: "Save a Google Place ID or a Local Falcon scan report link first."
    end
    id = connection.client_id if connection.callback_url == callback
    id ||= client.register(callback)
    connection.with_lock do
      connection.update!(client_id: id, callback_url: callback, verifier: verifier, state_digest: Digest::SHA256.hexdigest(state),
        initiator_id: current_user.id, state_expires_at: 10.minutes.from_now)
    end
    session[:local_falcon_state] = connection.state_digest
    redirect_to client.authorize_url(id, callback, state, verifier), allow_other_host: true, status: :see_other
  end

  def callback
    digest = Digest::SHA256.hexdigest(params[:state].to_s)
    expected = session.delete(:local_falcon_state).to_s
    connection = current_site.local_falcon_connection
    unless connection && ActiveSupport::SecurityUtils.secure_compare(expected, digest)
      return redirect_to local_falcon_connection_path, alert: "This authorisation expired. Start again."
    end
    # Rotate the claim before exchanging the one-time code. Disconnect/reconnect invalidates a pending callback.
    claim = SecureRandom.hex(32)
    verifier = connection.with_lock do
      next unless connection.state_digest == digest && connection.initiator_id == current_user.id && connection.state_expires_at&.future?
      value = connection.verifier
      connection.update!(state_digest: claim, verifier: nil)
      value
    end
    unless verifier && params[:code].present? && params[:error].blank?
      return redirect_to local_falcon_connection_path, alert: "Local Falcon access was not granted. Start again to connect."
    end
    token = LocalFalcon::Client.new.token(connection.client_id, grant_type: "authorization_code", code: params[:code],
      code_verifier: verifier, redirect_uri: connection.callback_url)
    raise LocalFalcon::Client::Error, "Local Falcon did not grant background access. Reconnect to continue." unless token["refresh_token"].present?
    accepted = current_site.with_lock do
      c = LocalFalconConnection.lock.find_by(id: connection.id, state_digest: claim, initiator_id: current_user.id)
      next false unless c&.state_expires_at&.future? && current_site.workspace.memberships.exists?(user: current_user, role: "owner")
      c.update!(ai_grant_revision: SecureRandom.uuid, access_token: token.fetch("access_token"), refresh_token: token.fetch("refresh_token"),
        token_expires_at: token.fetch("expires_in").to_i.seconds.from_now, status: "connected", verified_name: nil,
        state_digest: nil, initiator_id: nil, state_expires_at: nil, last_error: nil, sync_key: nil, synced_at: nil, last_attempt_at: nil)
      true
    end
    return redirect_to(local_falcon_connection_path, alert: "Authorisation was cancelled. Start again.") unless accepted
    LocalFalconSyncJob.perform_later(connection.id)
    redirect_to local_falcon_connection_path, notice: "Local Falcon authorised. Location verification and the first report refresh are queued."
  end

  def sync
    connection = current_site.local_falcon_connection
    return redirect_to(local_falcon_connection_path, alert: "Connect Local Falcon before refreshing.") unless connection&.refresh_token.present? && connection.status != "reconnect"
    LocalFalconSyncJob.perform_later(connection.id)
    redirect_to local_falcon_connection_path, notice: "Refresh queued. Reopen this screen to see the result."
  end

  def destroy
    c = current_site.local_falcon_connection
    creds = current_site.with_lock do
      next unless c && (c = LocalFalconConnection.lock.find_by(id: c.id))
      pair = [c.client_id, c.refresh_token]
      current_site.source_snapshots.linked_gbp_cache.delete_all
      c.destroy!
      pair
    end
    session.delete(:local_falcon_state)
    begin
      LocalFalcon::Client.new.revoke(*creds) if creds
      redirect_to local_falcon_connection_path, notice: "Disconnected. The linked Business Profile cache was removed. Completed Maps reports are still available."
    rescue LocalFalcon::Client::Error
      redirect_to local_falcon_connection_path, alert: "This app disconnected. Local Falcon could not confirm revocation; you can remove its grant in your account."
    end
  end
end
