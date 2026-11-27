class CompetingPagesController < ApplicationController
  before_action :no_store, except: :index
  before_action :require_site_manager, only: %i[update recommendation listing_check article_check]
  before_action :set_keyword_filter

  def index
    @keywords = current_site.keywords.order(:phrase)
    findings = current_findings.sort_by do |finding|
      evidence = finding.evidence
      clicks = evidence.fetch("clicks")
      [clicks["material_decline"] ? 0 : 1, clicks["trend"] == "down" ? 0 : 1, [clicks["change"].to_i, 0].min,
        -evidence.fetch("switch_count"), evidence.fetch("query"), evidence.fetch("device")]
    end
    @groups = findings.group_by { |finding| finding.disposition == "open" ? finding.level : "decided" }
    if @groups.empty? && @connection && @country
      weeks = SearchConsolePageWeek.where(site: current_site, property: @connection.property, country: @country)
      weeks = weeks.where(query: @keyword.phrase.downcase) if @keyword
      @latest_week = weeks.maximum(:week_start)
    end
    @through = findings.map { |finding| finding.evidence.dig("clicks", "current_end") }.compact.max
  end

  def show
    @finding = current_findings.find(params[:id])
    prepare_detail
  end

  def listing_check
    @finding = current_findings.find(params[:id])
    return head :not_found unless listing_source_available?
    return head :unprocessable_entity unless CompetingPages::ListingCheck.target_for(@finding)

    CompetingPages::ListingCheck.call(finding: @finding, version: params[:version])
    redirect_to competing_page_path(@finding, keyword_id: @keyword&.id, anchor: "listing-check"), status: :see_other
  rescue CompetingPages::ListingCheck::Busy
    redirect_to competing_page_path(@finding, keyword_id: @keyword&.id, anchor: "listing-check"),
      notice: "A listing check is already running. Refresh shortly to see the result.", status: :see_other
  rescue CompetingPages::ListingCheck::Stale
    @finding = current_findings.find(params[:id])
    flash.now[:alert] = "This review has changed. Read the latest figures before checking the Google result again."
    prepare_detail
    render :show, status: :conflict
  end

  def article_check
    @finding = current_findings.find(params[:id])
    return head :not_found unless listing_source_available?

    CompetingPages::ArticleCheck.call(finding: @finding, version: params[:version], capture_key: params[:capture_key])
    redirect_to competing_page_path(@finding, keyword_id: @keyword&.id, anchor: "ranking-article"), status: :see_other
  rescue CompetingPages::ArticleCheck::Busy
    redirect_to competing_page_path(@finding, keyword_id: @keyword&.id, anchor: "listing-check"),
      notice: "A check is already running. Refresh shortly to see the result.", status: :see_other
  rescue CompetingPages::ArticleCheck::Stale
    @finding = current_findings.find(params[:id])
    flash.now[:alert] = "The saved result has changed. Check the latest Google result before reviewing the page."
    prepare_detail
    render :show, status: :conflict
  end

  def recommendation
    run = current_site.with_lock do
      @finding = current_findings.lock.find(params[:id])
      next if params[:version] != @finding.updated_at.iso8601(6)
      AiRun.request_page_advice!(finding: @finding, user: current_user, retry_run_id: params[:retry_run_id])
    end
    unless run
      flash.now[:alert] = "This review has changed. Read the latest figures before asking for a recommendation."
      prepare_detail
      return render :show, status: :conflict
    end

    if run.status == "pending"
      if Schedules::WorkerMonitor.worker_available?
        AiRunJob.perform_later(run.id) if run.previously_new_record?
      else
        # A deliberate request on an owner-controlled installation can finish
        # with the normal spending reservation even while the local worker is off.
        AiRunJob.perform_now(run.id)
      end
    elsif run.status == "running"
      AiBriefScheduleJob.close_interrupted(AiRun.where(id: run.id))
    end
    redirect_to competing_page_path(@finding, keyword_id: @keyword&.id, anchor: "ai-recommendation"), status: :see_other
  rescue ActiveRecord::RecordInvalid => error
    redirect_to competing_page_path(@finding, keyword_id: @keyword&.id, anchor: "ai-recommendation"),
      alert: error.record.errors.full_messages.to_sentence, status: :see_other
  end

  def update
    result = current_site.with_lock do
      @finding = current_findings.lock.find(params[:id])
      next :stale unless params[:version] == @finding.updated_at.iso8601(6)
      next :invalid unless SiteFinding::DISPOSITIONS.include?(params[:disposition])
      @finding.update!(disposition: params[:disposition])
      :saved
    end

    case result
    when :stale
      flash.now[:alert] = "This review has changed. Read the latest findings before saving your decision."
      prepare_detail
      render :show, status: :conflict
    when :invalid
      head :unprocessable_entity
    else
      redirect_to competing_page_path(@finding, keyword_id: @keyword&.id), notice: "Your decision has been saved.", status: :see_other
    end
  end

  private

  def set_keyword_filter
    @keyword = current_site.keywords.find(params[:keyword_id]) if params[:keyword_id].present?
  end

  def current_findings
    @connection = current_site.search_console_connection
    @country = SearchConsole::DailyPositions.country_for(current_site)
    return SiteFinding.none unless @country && SearchConsole::Client.matches?(@connection&.property, current_site.host)
    return SiteFinding.none unless %w[connected delayed reconnect].include?(@connection.status)

    SiteFinding.current.competing_pages.where(site: current_site, keyword: @keyword || current_site.keywords)
      .where("evidence->>'property' = ? AND evidence->>'country' = ?", @connection.property, @country)
  end

  def prepare_detail
    @evidence = @finding.evidence
    @clicks = @evidence.fetch("clicks")
    @through = @clicks.fetch("current_end")
    weeks = @evidence.fetch("weeks")
    @pair = @evidence.fetch("pages")
    @latest_switch = CompetingPages::Comparison.latest_switch(weeks, @pair)
    @last_clear_week = weeks.reverse_each.find { |week| week["state"] == "leader" } unless @latest_switch
    @local_overlap = Tracking::OrganicPageOverlap.for(keyword: @finding.keyword, device: @evidence.fetch("device"), urls: @evidence.fetch("pages"))
    if listing_source_available?
      @listing_target = CompetingPages::ListingCheck.target_for(@finding)
      @listing_receipt = CompetingPages::ListingCheck.saved(@finding) if @listing_target
      if @listing_receipt&.dig("google", "other_result")
        @article_candidate = CompetingPages::ArticleCheck.candidate(@finding)
        @article_receipt = CompetingPages::ArticleCheck.saved(@finding) if @article_candidate
      end
    end
    return unless can_manage_site?
    advice_request = AiAssistant::PageAdviceRequest.new(finding: @finding, user: current_user)
    @advice_run = advice_request.current
    @advice_available = advice_request.available?
    @advice_waiting_for_worker = @advice_run&.status == "pending" && !Schedules::WorkerMonitor.worker_available?
    @advice_interrupted = @advice_run&.status == "running" && @advice_run.attempted_at&.before?(AiBriefScheduleJob::INTERRUPTED_AFTER.ago)
  end

  def listing_source_available?
    %w[connected delayed].include?(@connection.status)
  end
end
