class SearchConsoleController < ApplicationController
  before_action :require_workspace_owner, except: :show

  def show
    @connection = current_site.search_console_connection
    @configured = SearchConsole::Client.configured?
  end

  def authorize
    return redirect_to(search_console_path, alert: "Google OAuth has not been configured.") unless SearchConsole::Client.configured?
    state = SecureRandom.urlsafe_base64(32)
    verifier = SecureRandom.urlsafe_base64(64)
    target = SearchConsole::Client.authorization_url(state: state, verifier: verifier)
    current_site.with_lock do
      SearchConsoleGrant.where(site: current_site, user: current_user).delete_all
      SearchConsoleGrant.create!(site: current_site, user: current_user, state_digest: Digest::SHA256.hexdigest(state),
        verifier: verifier, expires_at: 10.minutes.from_now)
    end
    # An opaque nonce binds this flow to the initiating browser session. Tokens and the verifier stay server-side.
    session[:search_console_flow] = Digest::SHA256.hexdigest(state)
    redirect_to target, allow_other_host: true, status: :see_other
  rescue SearchConsole::Client::Error => e
    redirect_to search_console_path, alert: e.message
  end

  def callback
    state = params[:state].to_s
    digest = Digest::SHA256.hexdigest(state)
    expected = session.delete(:search_console_flow).to_s
    return redirect_to(search_console_path, alert: "The authorisation has expired. Start again.") unless state.present? && ActiveSupport::SecurityUtils.secure_compare(expected, digest)
    grant = SearchConsoleGrant.transaction do
      flow = SearchConsoleGrant.lock.find_by(site: current_site, user: current_user, state_digest: digest)
      next unless flow && flow.expires_at.future?
      # Consume the browser state before contacting Google. Keep a short-lived claim that Disconnect can cancel.
      flow.update!(state_digest: Digest::SHA256.hexdigest(SecureRandom.hex(32)))
      flow
    end
    return redirect_to(search_console_path, alert: "The authorisation has expired. Start again.") unless grant
    if params[:error].present? || params[:code].blank?
      grant.destroy!
      return redirect_to(search_console_path, alert: "Google access was not granted.")
    end
    client = SearchConsole::Client.new
    tokens = client.exchange(code: params[:code], verifier: grant.verifier)
    unless tokens.fetch("scope", "").split == [SearchConsole::Client::SCOPE] && tokens["refresh_token"].present?
      return redirect_to(search_console_path, alert: "A separate read-only, offline Google grant is required. Reconnect to continue.")
    end
    properties = client.properties(token: tokens.fetch("access_token"), host: current_site.host)
    accepted = current_site.with_lock do
      claim = SearchConsoleGrant.lock.find_by(id: grant.id, state_digest: grant.state_digest)
      next false unless claim && claim.expires_at.future? && current_site.workspace.memberships.exists?(user: current_user, role: "owner")
      claim.destroy!
      connection = current_site.search_console_connection || current_site.build_search_console_connection
      # Require explicit re-selection. A new grant must not expose an old grant's report.
      connection.update!(access_token: tokens.fetch("access_token"), refresh_token: tokens.fetch("refresh_token"),
        token_expires_at: Time.current + tokens.fetch("expires_in").to_i.seconds, allowed_properties: properties,
        property: nil, status: "choose_property", sync_key: nil, synced_at: nil, data_through: nil, report: {}, last_error: nil)
      true
    end
    return redirect_to(search_console_path, alert: "This authorisation was cancelled. Start again to connect.") unless accepted
    redirect_to search_console_path, notice: properties.empty? ? "Google did not return a verified root property matching this site." : "Choose the Google property to report on."
  rescue SearchConsole::Client::Error => e
    redirect_to search_console_path, alert: e.message
  rescue KeyError
    redirect_to search_console_path, alert: "Google returned an incomplete grant. Reconnect to continue."
  end

  def update
    connection = current_site.search_console_connection
    id = params[:property].to_s
    return redirect_to(search_console_path, alert: "Connect Google first.") unless connection
    valid = connection.with_lock do
      next false unless connection.status != "reconnect" && connection.refresh_token.present? && connection.allowed_properties.include?(id) && SearchConsole::Client.matches?(id, current_site.host)
      if connection.property != id
        connection.update!(property: id, status: "connected", report: {}, synced_at: nil, data_through: nil, last_error: nil, sync_key: nil)
      end
      true
    end
    return redirect_to(search_console_path, alert: "Choose a verified root property from this site's list.") unless valid
    SearchConsoleSyncJob.perform_later(connection.id)
    redirect_to search_console_path, notice: "Property confirmed. A scoped report is queued."
  end

  def market
    if current_site.tracking_mode == "dataforseo"
      return redirect_to search_console_path, alert: "This managed site uses its verified search location country."
    end
    country = params[:country].to_s.strip.upcase
    unless SearchConsole::DailyPositions::COUNTRIES.key?(country)
      return redirect_to search_console_path, alert: "Enter a two-letter ISO country code, such as GB or US."
    end
    current_site.update!(rank_country_code: country)
    redirect_to search_console_path, notice: "Search Console reporting country saved."
  end

  def sync
    connection = current_site.search_console_connection
    if connection&.property.present? && connection.refresh_token.present? && connection.status != "reconnect" && SearchConsole::Client.configured?
      SearchConsoleSyncJob.perform_later(connection.id)
      redirect_to search_console_path, notice: "Refresh queued. Reload this screen to see the result."
    else
      redirect_to search_console_path, alert: "Connect Google and confirm a matching property first."
    end
  end

  def destroy
    connection = current_site.search_console_connection
    current_site.with_lock do
      SearchConsoleGrant.where(site: current_site).delete_all
      connection&.destroy!
      SearchConsole::DailyPositions.remove_live!(current_site)
    end
    session.delete(:search_console_flow)
    redirect_to search_console_path, notice: "Search Console was disconnected. Saved tokens and reports for this connection were removed."
  end
end
