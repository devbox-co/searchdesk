class OverviewsController < ApplicationController
  def show
    # Older dashboard bookmarks can include filters for the rankings table.
    ranking_filters = params.permit(:source, :device, :day, :campaign)
    return redirect_to rankings_path(ranking_filters.to_h) if ranking_filters.present?
    return redirect_to setup_guide_path if can_manage_site? && current_site.setup_tour_pending?

    @today = Time.current.in_time_zone(current_site.time_zone).to_date
    @metric = params[:metric] == "impressions" ? "impressions" : "clicks"
    @device = params[:rank_device] == "desktop" ? "desktop" : "mobile"
    @performance = SearchConsole::PerformanceOverview.new(current_site)
    @daily = @performance.series(@metric)
    @rank_rows = Tracking::Dashboard.rows(site: current_site, date: @today, device: @device)
    @visibility_map = LocalFalcon::VisibilityMap.new(site: current_site, through: @today, report_id: params[:map_scan])
    @latest_audit = SiteAudit.where(site: current_site, host: current_site.host).order(created_at: :desc, id: :desc).first
    @latest_brief = AiRun.published_briefs_for(site: current_site, user: current_user, limit: 1).first
    @work = SeoWork.new(site: current_site, can_manage: can_manage_site?, owner: workspace_owner?)
    no_store
  end
end
