class DashboardController < ApplicationController
  def index
    @device = params[:device] == "desktop" ? "desktop" : "mobile"
    @today = Time.current.in_time_zone(current_site.time_zone).to_date
    @day = params[:day].present? ? Date.iso8601(params[:day]) : @today
    return redirect_to rankings_path(device: @device), alert: "Choose today or an earlier date." if @day > @today

    @rows = Tracking::Dashboard.rows(site: current_site, date: @day, device: @device)
    @open_action_count = KeywordAction.for_site(current_site).where(status: "open").count
  rescue Date::Error
    redirect_to rankings_path(device: @device), alert: "Choose a valid observation date."
  end
end
