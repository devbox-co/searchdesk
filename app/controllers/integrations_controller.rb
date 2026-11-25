class IntegrationsController < ApplicationController
  skip_before_action :require_authentication, :require_site, only: :catalogue
  before_action :require_site_manager, only: :update
  before_action :load_entry, only: [:show, :update]

  def index
    @automation_online = Schedules::WorkerMonitor.online?
    @entries = IntegrationCatalogue.search(params[:q])
    @entries = @entries.select { |entry| integration_state(entry)[:attention] } if params[:filter] == "attention"
    @available, @planned = @entries.partition { |entry| entry.mode != "Planned" }
    @show_guide = params[:q].blank? && params[:filter] != "attention"
    if @show_guide
      @campaign = Semrush::CampaignDashboard.new(site: current_site).selected
      @latest_grid = LocalFalcon::MapsSummary.latest(current_site).first&.snapshot
      @last_local_day = DailySlot.joins(tracking_series: :keyword)
        .where(keywords: {site_id: current_site.id}, tracking_series: {source: current_site.tracking_mode, archived_at: nil})
        .where(status: %w[ranked outside]).maximum(:day)
    end
  end

  def catalogue
    @entries = IntegrationCatalogue.search(params[:q])
  end

  def show
    @report_link = local_report_link if @entry.key == "local-falcon"
  end

  def update
    return head :not_found unless @entry.key == "local-falcon"
    current_site.with_lock do
      @report_link = local_report_link
      if params[:remove] == "1"
        @report_link.destroy! if @report_link.persisted?
      else
        @report_link.url = params.require(:site_report_link).permit(:url)[:url].to_s.strip
        @report_link.save!
      end
    end
    redirect_to integration_path(@entry.key), notice: params[:remove] == "1" ? "Report link removed." : "Report link saved."
  rescue ActiveRecord::RecordInvalid
    render :show, status: :unprocessable_entity
  end

  helper_method :integration_state

  private

  def load_entry
    @entry = IntegrationCatalogue.find!(params[:id])
  end

  def local_report_link
    SiteReportLink.find_or_initialize_by(site_id: current_site.id, provider: "local-falcon")
  end

  IMPORT_KEYS = {"google-search-console" => "gsc", "google-analytics" => "ga4", "semrush" => "semrush"}.freeze

  def integration_state(entry)
    entry = IntegrationCatalogue.find!(entry) if entry.is_a?(String)
    @integration_states ||= {}
    @integration_states[entry.key] ||= begin
      state = connection_state(entry)
      provider = IMPORT_KEYS[entry.key]
      if provider
        count, date = imported_totals.fetch(provider, [0, nil])
        state.merge(import_count: count, import_date: date, import_provider: provider)
      else
        state
      end
    end
  end

  def imported_totals
    @imported_totals ||= SourceSnapshot.visible_for(current_site).catalogue_imports.group(:provider)
      .pluck(:provider, Arel.sql("COUNT(*)"), Arel.sql("MAX(observed_on)"))
      .to_h { |provider, count, day| [provider, [count, day]] }
  end

  def business_profile_state
    connector = current_site.local_falcon_connection
    portal = { phase: :portal, label: "Provider portal", mode: "Native provider portal", detail: "Open the Business Profile manager", attention: false }
    return portal unless connector&.status == "connected" && connector.refresh_token.present? &&
      connector.synced_at && connector.synced_at > 29.days.ago && connector.place_id.present? && connector.verified_name.present?
    report = SourceSnapshot.visible_for(current_site).linked_gbp_cache.first
    return portal unless report && report.metrics["place_id"] == connector.place_id
    first = Date.iso8601(report.metrics.fetch("start"))
    last = Date.iso8601(report.metrics.fetch("end"))
    # The successful sync receipt records whether the linked grant returned GBP on its last read.
    return portal unless first == last - 27 && connector.result["gbp"] == "Business Profile metrics through #{last}"
    { phase: :linked, label: "Connected via Local Falcon", mode: "Linked account reporting",
      detail: "Reported period · #{first.strftime('%d %b %Y')} to #{last.strftime('%d %b %Y')}", report: report, attention: false }
  rescue Date::Error, KeyError, TypeError
    portal
  end

  def connection_state(entry)
    case entry.key
    when "openai"
      connection = AiConnection.find_by(workspace: current_workspace)
      label = helpers.ai_connection_label(connection)
      { phase: label == "Ready" ? :connected : :empty, label: label, mode: entry.mode,
        detail: AiSetting.exists?(site: current_site, enabled: true) ? "Assistant enabled for this site" : "Assistant off for this site",
        attention: %w[Reconnect].include?(label) || ["Credits exhausted", "Budget reached"].include?(label) }
    when "google-business-profile"
      business_profile_state
    when "semrush"
      { phase: imported_totals.key?("semrush") ? :imported : :empty, label: imported_totals.key?("semrush") ? "Imported reports" : "No imported reports",
        mode: "File import", detail: "Automatic API sync unavailable", attention: false }
    when "google-search-console", "google-analytics"
      connection = entry.key == "google-analytics" ? current_site.analytics_connection : current_site.search_console_connection
      google_state(connection, entry.key == "google-analytics" ? :property_id : :property)
    when "local-falcon"
      @stored_link ||= local_report_link
      connector = current_site.local_falcon_connection
      if connector&.refresh_token.present?
        phase = { "delayed" => :delayed, "reconnect" => :reconnect }.fetch(connector.status, connector.synced_at && connector.verified_name.present? ? :connected : :pending)
        phase = :stale if phase == :connected && connector.synced_at < 2.days.ago
        label = {delayed: "Sync delayed", reconnect: "Reconnect", connected: "Connected", stale: "Refresh overdue", pending: "Verifying location"}.fetch(phase)
        return { phase: phase, label: label, detail: connector.last_error.presence || (connector.synced_at && "Last refreshed #{connector.synced_at.in_time_zone(current_site.time_zone).to_date}") || "Awaiting first verified refresh", attention: phase != :connected }
      end
      return {phase: :reconnect, label: "Reconnect", detail: "Reconnect to refresh existing reports", attention: true} if connector&.status == "reconnect"
      { phase: @stored_link.persisted? ? :link : :available, label: @stored_link.persisted? ? "Link saved" : "Available", detail: "Connect to refresh existing reports or save a report link", attention: false }
    when "dataforseo"
      managed_rank_state
    when "rank-import"
      manual = current_site.tracking_mode == "manual"
      { phase: manual ? :available : :inactive, label: manual ? "Available" : "Manual mode required", detail: "A file describes one scoped observation", attention: false }
    else
      { phase: entry.mode == "Planned" ? :planned : :portal, label: entry.mode, detail: entry.mode == "Planned" ? "No adapter installed" : "Open directly · no automatic sync", attention: false }
    end
  end

  def managed_rank_state
    site = current_site
    return {phase: :inactive, label: "Not selected", detail: "Use a managed site to schedule observations.", attention: false} unless site.tracking_mode == "dataforseo"
    return {phase: :setup, label: "Provider setup required", detail: "Ask your administrator to configure DataForSEO for this installation.", attention: true} unless Tracking::DataForSeo.enabled?
    if Tracking::DataForSeo.daily_task_limit.zero?
      return {phase: :limit, label: "Daily allowance is zero", detail: "New DataForSEO checks are disabled by the operator. Contact your administrator to review the daily task allowance.", attention: true}
    end
    unless site.rank_location_verified_at && site.rank_location_name == site.location && site.rank_location_code.to_i.positive?
      return {phase: :location, label: "Location verification needed", detail: "Ask your administrator to verify the provider town before collecting local readings.", attention: true}
    end
    series = TrackingSeries.current.joins(:keyword).where(keywords: {site_id: site.id}, source: "dataforseo")
    active = series.where(paused: false)
    unless active.exists?
      return {phase: :paused, label: "Tracking paused", detail: "DataForSEO is configured. Resume a keyword's device in Rankings to schedule readings.", attention: false} if series.exists?
      return {phase: :empty_watchlist, label: "No keywords enrolled", detail: "DataForSEO is configured. Add a keyword and device in Rankings to schedule readings.", attention: false}
    end
    eligible = active.where("settings->>'location_code' = ?", site.rank_location_code.to_s)
    unless eligible.exists?
      return {phase: :location, label: "Keyword location changed", detail: "Re-enrol a keyword for this verified town to schedule DataForSEO readings.", attention: true}
    end
    today = Time.current.in_time_zone(site.time_zone).to_date
    if DailySlot.where(tracking_series_id: eligible.select(:id), day: today, status: %w[ranked outside]).exists?
      return {phase: :received, label: "Reading received today", detail: "DataForSEO returned a local organic reading today. Rankings shows the result for each keyword and device.", attention: false}
    end
    {phase: :ready, label: "Configured · awaiting reading", detail: "DataForSEO is configured with active keyword tracking. Check Rankings for today's readings and any holds.", attention: false}
  end

  def google_state(connection, property_field)
    phase = connection&.status.to_s
    phase = "absent" if connection&.refresh_token.blank? && phase != "reconnect"
    phase = "choose_property" if phase == "connected" && connection.public_send(property_field).blank?
    phase = "pending" if phase == "connected" && connection.synced_at.nil?
    phase = "stale" if phase == "connected" && connection.synced_at < 2.days.ago
    label = { "connected" => "Connected", "pending" => "Connected · first report pending", "stale" => "Refresh overdue",
      "choose_property" => "Choose property", "delayed" => "Sync delayed", "reconnect" => "Reconnect", "error" => "Needs attention" }
    synced_at = connection&.synced_at
    detail = synced_at ? "Last successful sync #{synced_at.in_time_zone(current_site.time_zone).strftime('%d %b %Y, %H:%M %Z')}" : "No successful sync recorded"
    { phase: phase.to_sym, label: label.fetch(phase, "Not connected"), detail: detail, attention: !%w[absent connected].include?(phase) }
  end
end
