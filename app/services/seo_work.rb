class SeoWork
  include Rails.application.routes.url_helpers

  def initialize(site:, can_manage:, owner:, now: Time.current)
    @site = site
    @can_manage = can_manage
    @owner = owner
    @now = now
  end

  def keyword_count
    @keyword_count ||= @site.keywords.count
  end

  def schedules
    @schedules ||= (Schedules::Workflows.new(site: @site, now: @now).rows +
      Schedules::Sources.new(site: @site, now: @now).rows).index_by { |row| row.fetch(:key) }
  end

  def reviews
    @reviews ||= begin
      actions = KeywordAction.for_site(@site).where(status: "open")
      findings = SiteFinding.for_current_search_scope(@site).where(level: "review", disposition: "open")
      tasks = @site.project_tasks.with_current_status(ProjectTask::ACTIONABLE_STATES)
      [
        approval_item,
        task_item(tasks.by_priority.first, tasks.count),
        action_item(actions.includes(tracking_series: :keyword).order(observed_on: :desc, id: :desc).first, actions.count),
        finding_item(findings.includes(:keyword).order(Arel.sql("evidence->'clicks'->>'material_decline' DESC NULLS LAST"),
          updated_at: :desc, id: :desc).first, findings.count),
        missing_evidence_item
      ].compact
    end
  end

  def next_steps
    search = schedules.fetch("search-console")
    maps = schedules.fetch("local-falcon")
    setup = [
      ranking_step,
      source_step(search, title: "Get clicks and impressions from Google", icon: :search,
        detail: "Connect Search Console and choose this website’s property."),
      source_step(maps, title: "See where customers find you on Google Maps", icon: :map_pin,
        detail: "Connect Local Falcon to import completed scans.")
    ].compact
    # Surface repair work even when the team has open reviews.
    urgent, optional = setup.partition { |item| item[:tone] == :warning }
    expiring, other_reviews = reviews.partition { |item| item[:deadline] }
    (expiring + urgent + other_reviews + optional).first(3)
  end

  def source_link(row, normal_label:)
    case row[:status]
    when "Not connected"
      @can_manage ? "Connect" : "View connection"
    when "Reconnect"
      @can_manage ? "Reconnect" : "View connection"
    when "Setup needed"
      @can_manage ? "Review setup" : "View connection"
    else
      normal_label
    end
  end

  private

  def ranking_step
    if keyword_count.zero?
      return { icon: :target, label: "Keyword tracking", status: "Setup needed", tone: :idle,
        title: "Choose a search to track",
        detail: @can_manage ? "Start with a service and town your customers search for." : "Ask a site manager to add your first search term.",
        path: @can_manage ? new_keyword_path : rankings_path, link: @can_manage ? "Add a keyword" : "View rankings" }
    end
    row = schedules.fetch("rankings")
    if row[:tone] == :warning
      return { icon: :target, label: "Keyword tracking", status: row[:status], tone: :warning,
        title: "Check your ranking collection", detail: row[:next_label],
        path: schedules_path(anchor: "schedule-collection"), link: "View collection status" }
    end
    return unless @site.tracking_mode == "manual" && row[:last_at].nil?
    { icon: :target, label: "Keyword tracking", status: "Manual import", tone: :idle,
      title: "Add your first ranking reading", detail: "In Rankings, open a keyword to see its device and import options.",
      path: rankings_path(source: "local"), link: "Open rankings" }
  end

  def source_step(row, title:, icon:, detail:)
    return unless row[:tone] == :warning || row[:status] == "Not connected"
    { icon: icon, label: row[:name], status: row[:status], tone: row[:tone],
      title: title, detail: row[:tone] == :warning || !@can_manage ? row[:next_label] : detail,
      path: row[:path], link: source_link(row, normal_label: "Check connection") }
  end

  def approval_item
    pending = workflow_runs.pending_review(@now).order(:updated_at, :id)
    run = pending.first
    return unless run

    report_item(run).merge(status: "Awaiting owner approval", deadline: run.review_deadline,
      link: @owner ? "Review draft" : "View draft", count: pending.count,
      list_path: seo_workflows_path(anchor: "awaiting-approval"))
  end

  def missing_evidence_item
    missing = workflow_runs.latest_by_template.to_a.select { |run| run.status == "missing_evidence" }
    run = missing.max_by { |record| [record.period_on, record.id] }
    return unless run

    report_item(run).merge(status: "Needs evidence", link: "See what’s needed", count: missing.size,
      list_path: seo_workflows_path(anchor: "recent-results"))
  end

  def workflow_runs
    @site.seo_workflow_runs.where(site_host: @site.host)
  end

  def report_item(run)
    { icon: :file_text, label: "SEO task reports", title: run.template.name, tone: :warning,
      detail: "Reporting period through #{run.period_on.strftime('%-d %b %Y')}", path: seo_workflow_path(run) }
  end

  def task_item(task, count)
    return unless task
    { icon: :tasks, label: "Project tasks", title: task.title, status: task.effective_status.humanize,
      tone: task.effective_status == "in_progress" ? :active : :warning,
      detail: "#{task.priority.humanize} priority", date: task.updated_at, date_label: "Updated",
      path: project_task_path(task), link: "Open task", count: count, list_path: project_tasks_path }
  end

  def action_item(action, count)
    return unless action
    { icon: :actions, label: "Keyword recommendations", title: action.title, status: "Open", tone: :warning,
      detail: "#{action.keyword.phrase} · #{action.tracking_series.device.capitalize}", date: action.observed_on,
      date_label: "Observed", path: action_draft_path(action), link: "View next steps", count: count,
      list_path: actions_path(anchor: "keyword-recommendations") }
  end

  def evidence_date(value)
    Date.iso8601(value.to_s)
  rescue Date::Error
    nil
  end

  def finding_item(finding, count)
    return unless finding
    period_end = finding.evidence.dig("clicks", "current_end")
    { icon: :layers, label: "Competing pages", title: "Compare pages for “#{finding.keyword.phrase}”",
      status: "Review", tone: :warning, detail: finding.evidence["device"].to_s.capitalize,
      date: evidence_date(period_end), date_label: "Data through",
      path: competing_page_path(finding), link: "Review pages", count: count, list_path: competing_pages_path }
  end
end
