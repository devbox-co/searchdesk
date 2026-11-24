class IntegrationsController < ApplicationController
  skip_before_action :require_authentication, :require_site, only: :catalogue
  before_action :require_site_manager, only: :update
  before_action :load_entry, only: [:show, :update]

  def index
    active = SolidQueue::Process.where(last_heartbeat_at: 3.minutes.ago..).distinct.pluck(:kind)
    @automation_online = (%w[Worker Scheduler Dispatcher] - active).empty?
    @entries = IntegrationCatalogue.search(params[:q])
    @entries = @entries.select { |entry| integration_state(entry)[:attention] } if params[:filter] == "attention"
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
    portal = { label: "Provider portal", mode: "Native provider portal", detail: "Open the Business Profile manager", attention: false }
    return portal unless connector&.status == "connected" && connector.refresh_token.present? &&
      connector.synced_at && connector.synced_at > 29.days.ago && connector.place_id.present? && connector.verified_name.present?
    report = SourceSnapshot.visible_for(current_site).linked_gbp_cache.first
    return portal unless report && report.metrics["place_id"] == connector.place_id
    first = Date.iso8601(report.metrics.fetch("start"))
    last = Date.iso8601(report.metrics.fetch("end"))
    # The successful sync receipt records whether the linked grant returned GBP on its last read.
    return portal unless first == last - 27 && connector.result["gbp"] == "Business Profile metrics through #{last}"
    { label: "Connected via Local Falcon", mode: "Linked account reporting",
      detail: "Reported period · #{first.strftime('%d %b %Y')} to #{last.strftime('%d %b %Y')}", report: report, attention: false }
  rescue Date::Error, KeyError, TypeError
    portal
  end

  def connection_state(entry)
    case entry.key
    when "google-business-profile"
      business_profile_state
    when "semrush"
      { label: imported_totals.key?("semrush") ? "Imported reports" : "No imported reports",
        mode: "File import", detail: "Automatic API sync unavailable", attention: false }
    when "google-search-console", "google-analytics"
      connection = entry.key == "google-analytics" ? current_site.analytics_connection : current_site.search_console_connection
      state = connection&.status
      state = nil if connection && connection.refresh_token.blank? && state != "reconnect"
      synced_at = connection&.synced_at
      detail = synced_at ? "Last successful sync #{synced_at.in_time_zone(current_site.time_zone).strftime('%d %b %Y, %H:%M %Z')}" : "No successful sync recorded"
      { label: { "connected" => "Connected", "choose_property" => "Choose property", "delayed" => "Sync delayed", "reconnect" => "Reconnect", "error" => "Needs attention" }.fetch(state, "Not connected"), detail: detail, attention: state != "connected" || synced_at.nil? || synced_at < 2.days.ago }
    when "local-falcon"
      @stored_link ||= local_report_link
      connector = current_site.local_falcon_connection
      if connector&.refresh_token.present?
        label = { "delayed" => "Sync delayed", "reconnect" => "Reconnect" }.fetch(connector.status, connector.synced_at ? "Connected" : "Verifying location")
        return { label: label, detail: connector.last_error || (connector.synced_at && "Last refreshed #{connector.synced_at.to_date}") || "First refresh queued", attention: connector.status != "connected" }
      end
      { label: @stored_link.persisted? ? "Link saved" : "Available", detail: "Connect to refresh existing reports or save a report link", attention: false }
    when "dataforseo"
      selected = current_site.tracking_mode == "dataforseo"
      return { label: "Not selected", detail: "Use a managed site to schedule observations", attention: false } unless selected
      enabled = Tracking::DataForSeo.enabled?
      { label: enabled ? "Collection enabled" : "Provider setup required", detail: "Collection status appears beside each keyword", attention: !enabled }
    when "rank-import"
      manual = current_site.tracking_mode == "manual"
      { label: manual ? "Available" : "Manual mode required", detail: "A file describes one scoped observation", attention: false }
    else
      { label: entry.mode, detail: entry.mode == "Planned" ? "No adapter installed" : "Open directly · no automatic sync", attention: false }
    end
  end
end
