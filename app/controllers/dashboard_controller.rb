class DashboardController < ApplicationController
  def index
    @device = params[:device] == "desktop" ? "desktop" : "mobile"
    @today = Time.current.in_time_zone(current_site.time_zone).to_date
    requested = Date.iso8601(params[:day].to_s) if params[:day].present?
    @day = requested || @today
    @country_label = current_site.rank_country_code == "GB" ? "UK" : current_site.rank_country_code.presence
    @campaign = Semrush::CampaignDashboard.new(site: current_site, requested_day: requested, campaign: params[:campaign])
    @source = params[:source].presence_in(%w[local gsc campaign])
    if @source.nil? || @source == "local"
      @rows = Tracking::Dashboard.rows(site: current_site, date: @day, device: @device)
      if @source.nil? && @rows.none? { |row| row[:as_of] }
        @positions = SearchConsole::PositionDashboard.new(site: current_site, requested_day: requested)
        last_gsc = @positions.rows.filter_map { |row| row.dig(:latest, :date) }.max
        @source = "gsc" if @positions.available?
        @source = "campaign" if @campaign.cutoff && (last_gsc.nil? || @campaign.cutoff >= last_gsc)
      end
    end
    case @source
    when "gsc"
      @today = Time.current.in_time_zone(SearchConsole::DailyPositions::ZONE).to_date
      @positions ||= SearchConsole::PositionDashboard.new(site: current_site, requested_day: requested)
      @day = @positions.day
    when "campaign"
      @day = @campaign.day
    else
      @source = "local"
      @open_action_count = KeywordAction.for_site(current_site).where(status: "open").count
    end
    return redirect_to rankings_path(source: @source, device: @device, campaign: params[:campaign]), alert: "Choose today or an earlier date." if @day > @today
  rescue Date::Error
    redirect_to rankings_path(source: params[:source], device: @device), alert: "Choose a valid observation date."
  end
end
