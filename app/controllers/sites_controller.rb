class SitesController < ApplicationController
  skip_before_action :require_site

  def select
    site = available_sites.find(params[:id])
    select_current_site(site)
    redirect_to dashboard_path
  end
end
