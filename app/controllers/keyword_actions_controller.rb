class KeywordActionsController < ApplicationController
  before_action :require_site_manager, only: :update

  def index
    @keywords = current_site.keywords.order(:phrase)
    @state = %w[open resolved].include?(params[:state]) ? params[:state] : "open"
    @actions = site_actions.includes(tracking_series: :keyword).where(status: @state).order(observed_on: :desc, id: :desc)
    @keyword = @keywords.find(params[:keyword_id]) if params[:keyword_id].present?
    @actions = @actions.where(tracking_series: { keyword_id: @keyword.id }) if @keyword
  end

  def update
    action = site_actions.find(params[:id])
    state = params.require(:status)
    return head :unprocessable_entity unless %w[open resolved].include?(state)
    action.update!(status: state)
    redirect_to actions_path(state: state == "open" ? "open" : "resolved"), notice: state == "open" ? "Action reopened." : "Action marked reviewed."
  end

  private

  def site_actions
    KeywordAction.for_site(current_site)
  end
end
