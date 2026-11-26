class ActionDraftsController < ApplicationController
  before_action :find_action
  before_action :require_site_manager, only: :create

  def create
    return head :unprocessable_entity unless @action.status == "open" && ActionDraft.capture!(@action)
    redirect_to action_draft_path(@action), status: :see_other
  end

  def show
    @draft = ActionDraft.current_for(@action)
    @historical = @action.observed_on < @action.tracking_series.date_in_zone.yesterday
    @wording = WordingSetting.find_by(site: current_site)&.selected_line
  end

  private

  def find_action
    @action = KeywordAction.joins(tracking_series: :keyword).where(keywords: {site_id: current_site.id}).find(params[:id])
  end
end
