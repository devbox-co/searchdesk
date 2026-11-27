class ActionDraftsController < ApplicationController
  before_action :find_action
  before_action :require_site_manager, only: %i[create update_choice check_link]

  def create
    return head :unprocessable_entity unless @action.status == "open" && ActionDraft.capture!(@action)
    redirect_to action_draft_path(@action), status: :see_other
  end

  def show
    load_review
  end

  def update_choice
    choice = params.expect(:owner_choice)
    note = params.permit(:owner_choice_note)[:owner_choice_note].to_s.strip.presence
    with_locked_review do
      unless submitted_review? && @guide.choice_available?
        flash.now[:alert] = "This review has changed. Check the latest next steps before choosing."
        return render :show, status: :conflict
      end

      attributes = {owner_choice: choice, owner_choice_note: note}
      attributes[:link_check_started_at] = nil if choice == "prefer_ranking"
      unless @draft.update(attributes)
        flash.now[:alert] = @draft.errors.full_messages.to_sentence
        @draft.reload
        return render :show, status: :unprocessable_entity
      end
    end
    return run_link_check(recheck: false) if choice == "keep_preferred"
    redirect_to action_draft_path(@action, anchor: "handoff-heading"), notice: "Your choice and handoff are saved.", status: :see_other
  end

  def check_link
    run_link_check(recheck: params[:recheck] == "1")
  end

  private

  def run_link_check(recheck:)
    claim = with_locked_review do
      next :changed unless submitted_review? && @guide.link_check_available?
      next :running if @draft.link_check_running?
      next :cached if @draft.reuse_link_check?(recheck: recheck)

      started_at = Time.current.floor(6)
      @draft.update!(link_check_started_at: started_at)
      started_at
    end

    case claim
    when :changed then return changed_link_check
    when :running then return show_link_check("A link check is already in progress. Refresh shortly to see the result.")
    when :cached then return show_link_check("Showing the most recent link check.")
    end

    draft_id = @draft.id
    evidence = SiteAudits::TargetedLinkCheck.new(host: @action.keyword.site.host,
      source_url: @guide.winning_url, target_url: @guide.preferred_url).call
    saved = with_locked_review do
      next false unless submitted_review? && @guide.link_check_available? && @draft.link_check_started_at == claim
      @draft.update!(link_check_result: evidence, link_checked_at: Time.current, link_check_started_at: nil)
    end
    return changed_link_check unless saved

    show_link_check("Link check saved.")
  ensure
    # Release only this request's lease if the receipt changed or the check raised.
    ActionDraft.where(id: draft_id, link_check_started_at: claim).update_all(link_check_started_at: nil) if draft_id && !saved
  end

  def changed_link_check
    flash.now[:alert] = "This review has changed. Open the latest next steps to check the current pages."
    render :show, status: :conflict
  end

  def show_link_check(message)
    redirect_to action_draft_path(@action, anchor: "link-check"), notice: message, status: :see_other
  end

  def submitted_review?
    @draft && @draft.id.to_s == params[:draft_id].to_s
  end

  def with_locked_review
    # Follow the same series-before-action lock order as ranking collection.
    @action.keyword.with_lock do
      @action.tracking_series.lock!
      @action.lock!
      raise ActiveRecord::RecordNotFound unless @action.keyword.site_id == current_site.id
      load_review
      yield
    end
  end

  def load_review
    @draft = ActionDraft.current_for(@action)
    @historical = @action.observed_on < @action.tracking_series.date_in_zone.yesterday
    @guide = SeoSkills::ActionGuide.new(action: @action, draft: @draft, historical: @historical)
    @wording = WordingSetting.find_by(site: current_site)&.selected_line
  end

  def find_action
    @action = KeywordAction.for_site(current_site).find(params[:id])
  end
end
