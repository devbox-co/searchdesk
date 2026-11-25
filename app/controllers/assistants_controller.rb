class AssistantsController < ApplicationController
  before_action :no_store
  before_action :load_configuration, only: %i[show ask run]
  before_action :require_workspace_owner, only: :clear

  STARTERS = {
    "movement" => "What changed since tracking began?",
    "page" => "Which pages are appearing for my tracked keywords?",
    "priority" => "What should I check first?"
  }.freeze

  def show
    @starter = STARTERS[params[:starter]]
    @review_day = Time.current.in_time_zone(current_site.time_zone).to_date
    facts = review_facts(@review_day)
    @playbooks = AiAssistant::Playbooks.for_facts(facts)
    @review = @playbooks.first(3).map do |playbook|
      matches = facts.select { |fact| playbook.matches?(fact) }
      # Prefer an individual observed keyword or action over the group total.
      example = matches.find { |fact| fact.fetch("url").to_s.include?("#") } || matches.first
      [playbook, example]
    end
    @history = AiRun.where(site: current_site, kind: "question", user: current_user)
      .order(created_at: :desc, id: :desc).limit(40).select { |run| run.visible_to?(user: current_user) }.first(12)
    @briefs = AiRun.published_briefs_for(site: current_site, user: current_user)
    if workspace_owner?
      current = AiRun.where(site: current_site, kind: "brief", report_on: @review_day, erased_at: nil).order(id: :desc).first
      @today_brief = current if current&.visible_to?(user: current_user)
    end
  end

  def ask
    return head :forbidden unless @setting.may_ask?(user: current_user)
    unless @can_ask
      return redirect_to assistant_path, alert: "Questions are paused. Check the OpenAI connection and workspace allowance.", status: :see_other
    end

    parent = visible_run(params[:parent_id]) if params[:parent_id].present?
    if parent && (!%w[question brief].include?(parent.kind) || !%w[complete fallback].include?(parent.status))
      return head :unprocessable_entity
    end
    key = params[:request_key].to_s
    return head :unprocessable_entity unless key.match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i)
    question = params[:question].to_s.strip
    if params.key?(:playbook)
      playbook = AiAssistant::Playbooks.find(params[:playbook].to_s)
      return head :unprocessable_entity unless playbook
      day = parent ? review_day_for(parent) : Time.current.in_time_zone(current_site.time_zone).to_date
      facts = parent ? cited_facts(parent) : review_facts(day)
      return head :unprocessable_entity unless facts.any? { |fact| playbook.matches?(fact) }
      question = playbook.question
    end
    run = AiRun.request!(site: current_site, user: current_user, kind: "question",
      question: question, parent: parent, report_on: day, request_key: key)
    AiRunJob.perform_later(run.id) if run.previously_new_record?
    redirect_to assistant_run_path(run), status: :see_other
  rescue ActiveRecord::RecordInvalid => error
    redirect_to assistant_path, alert: error.record.errors.full_messages.to_sentence, status: :see_other
  end

  def run
    @run = visible_run(params[:id])
    if @can_ask && @run.kind != "test" && %w[complete fallback].include?(@run.status)
      @playbooks = AiAssistant::Playbooks.for_facts(cited_facts(@run)).reject { |book| book.question == @run.question }
      @review_day = review_day_for(@run)
    end
  end

  def erase
    run = visible_run(params[:id])
    return head :forbidden unless workspace_owner? || (run.kind == "question" && run.user_id == current_user.id)

    run.erase_content!
    redirect_to assistant_path, notice: "Removed the saved content and its follow-ups.", status: :see_other
  end

  def clear
    AiRun.erase_history!(site: current_site)
    redirect_to assistant_path, notice: "Assistant history cleared for #{current_site.name}. Spending receipts are retained.", status: :see_other
  end

  private

  def review_facts(day)
    AiAssistant::Evidence.build(site: current_site, setting: @setting, kind: "brief",
      day: day, question: "").fetch("facts")
  end

  def cited_facts(run)
    ids = Array(run.answer["findings"]).flat_map { |finding| Array(finding["fact_ids"]) }
    Array(run.evidence["facts"]).select { |fact| ids.include?(fact["id"]) }
  end

  def review_day_for(run)
    Date.iso8601(run.evidence.fetch("day"))
  rescue KeyError, Date::Error, TypeError
    run.report_on
  end

  def load_configuration
    @setting = AiSetting.find_or_initialize_by(site: current_site)
    @connection = AiConnection.find_by(workspace: current_workspace)
    @can_ask = AiConnection.owner_controlled_installation? && @setting.may_ask?(user: current_user) &&
      @connection&.status == "ready" && @connection.monthly_budget_cents.positive? &&
      @connection.month_spend_microusd < @connection.monthly_budget_cents * 10_000
  end

  def visible_run(id)
    run = AiRun.find_by!(site: current_site, id: id)
    raise ActiveRecord::RecordNotFound unless run.visible_to?(user: current_user)
    run
  end
end
