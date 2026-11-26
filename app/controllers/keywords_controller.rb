class KeywordsController < ApplicationController
  before_action :require_site_manager, only: [:new, :create, :update, :preferred_page]

  def show
    @keyword = current_site.keywords.find(params[:id])
    @device = params[:device] == "mobile" ? "mobile" : "desktop"
    @series = @keyword.tracking_series.current.find_by(device: @device)
    @range = %w[7 30 all].include?(params[:range]) ? params[:range] : "30"
    @slots = []
    return unless @series
    scope = @series.daily_slots.includes(:rank_observation).order(day: :desc)
    scope = scope.where(day: (@series.date_in_zone - @range.to_i + 1)..) unless @range == "all"
    if params[:before].present?
      cursor = Date.iso8601(params[:before])
      scope = scope.where(day: ...cursor)
    end
    @slots = scope.limit(101).to_a
    @more = @slots.pop if @slots.size > 100
    @placements = Tracking::PlacementHistory.for_slots(@slots) if @series.source == "dataforseo"
    @placements = Tracking::PlacementHistory.for_slots(@slots) if @series.source == "dataforseo"
  rescue Date::Error
    head :bad_request
  end

  def update
    keyword = current_site.keywords.find(params[:id])
    series = keyword.tracking_series.current.find_by!(device: params.require(:device))
    state = params.require(:tracking)
    return head :unprocessable_entity unless %w[pause resume].include?(state)
    series.with_lock { series.update!(paused: state == "pause") }
    redirect_to keyword_path(keyword, device: series.device), notice: series.paused? ? "Tracking paused for this device." : "Tracking resumed for this device."
  end

  def new
    @keyword = current_site.keywords.new
  end

  def preferred_page
    keyword = current_site.keywords.find(params[:id])
    supplied = params.require(:keyword).permit(:preferred_url).fetch(:preferred_url).to_s.strip.presence
    url = Tracking::ResultUrl.parse(supplied) if supplied
    if supplied && !(url && supplied.bytesize <= 2048 && Tracking::ResultUrl.host_matches?(current_site.host, url.host))
      return redirect_to keyword_path(keyword), alert: "Choose a page on this website."
    end
    keyword.with_lock { keyword.update!(preferred_url: supplied) }
    redirect_to keyword_path(keyword, device: params[:device]), notice: "Preferred page updated for future observations."
  end

  def create
    attrs = params.require(:keyword).permit(:phrase, :preferred_url)
    @keyword = current_site.keywords.new(attrs)
    Tracking::Enrollment.call(site: current_site, phrase: attrs[:phrase], preferred_url: attrs[:preferred_url].presence)
    redirect_to(params[:setup] == "1" ? setup_guide_path : rankings_path, notice: "Keyword added to this site's watchlist.")
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ArgumentError => e
    @keyword.errors.add(:base, e.is_a?(ActiveRecord::RecordNotUnique) ? "This keyword is already on the watchlist." : e.message)
    render :new, status: :unprocessable_entity
  end
end
