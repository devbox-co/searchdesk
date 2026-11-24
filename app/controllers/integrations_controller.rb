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

  def integration_state(entry)
    case entry.key
    when "google-search-console"
      @search_console_connection ||= current_site.search_console_connection
      state = @search_console_connection&.status
      synced_at = @search_console_connection&.synced_at
      detail = synced_at ? "Last successful sync #{synced_at.in_time_zone(current_site.time_zone).strftime('%d %b %Y, %H:%M %Z')}" : "No successful sync recorded"
      { label: { "connected" => "Connected", "choose_property" => "Choose property", "delayed" => "Sync delayed", "reconnect" => "Reconnect", "error" => "Needs attention" }.fetch(state, "Not connected"), detail: detail, attention: state != "connected" || synced_at.nil? || synced_at < 2.days.ago }
    when "local-falcon"
      @stored_link ||= local_report_link
      { label: @stored_link.persisted? ? "Link saved" : "Add report link", detail: "View at provider · no automatic sync", attention: false }
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
