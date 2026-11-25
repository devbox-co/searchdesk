class SiteAuditsController < ApplicationController
  before_action :require_workspace_owner, only: %i[create schedule]

  def show
    scope = SiteAudit.where(site: current_site, host: current_site.host).order(created_at: :desc, id: :desc)
    @recent_audits = scope.limit(8).to_a
    @audit = params[:run].present? ? scope.find(params[:run]) : @recent_audits.first
    @connection = current_site.search_console_connection
    @performance = SearchConsole::PerformanceOverview.new(current_site)
    return unless @connection && %w[connected delayed].include?(@connection.status) &&
      SearchConsole::Client.matches?(@connection.property, current_site.host)

    @property = @connection.property
    @sitemaps = @connection.report["sitemaps"] if @connection.report&.fetch("property", nil) == @property
  end

  def schedule
    enabled = params.require(:site).permit(:weekly_site_audit_enabled)[:weekly_site_audit_enabled]
    return head :unprocessable_entity unless %w[0 1].include?(enabled)
    current_site.update!(weekly_site_audit_enabled: enabled == "1")
    redirect_to site_audit_path, status: :see_other, notice: "Crawl schedule saved."
  end

  def create
    audit = SiteAudit.request!(site: current_site)
    redirect_to site_audit_path(run: audit.id), status: :see_other
  end
end
