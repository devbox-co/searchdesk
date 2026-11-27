class SeoWorkflowsController < ApplicationController
  before_action :require_workspace_owner, except: %i[overview index setup show competitor_capture local_services_capture evidence_preview open_rollup_location]
  before_action :load_template, only: %i[run schedule]
  before_action :load_run, only: %i[show review refresh_draft record_delivery preview_delivery confirm_delivery cancel_delivery publish]

  def overview
    now = Time.current
    @work = SeoWork.new(site: current_site, can_manage: can_manage_site?, owner: workspace_owner?, now: now)
    @worker_health = Schedules::WorkerMonitor.new(now: now).health
    no_store
  end

  def index
    no_store
    @now = Time.current.in_time_zone(current_site.time_zone)
    @templates = SeoWorkflows::Catalogue::TEMPLATES.values
    @evidence_kind = params[:evidence].presence_in(SeoWorkflows::EvidenceImport::KINDS.keys)
    schedules = current_site.seo_workflow_schedules.to_a
    @schedules_by_template = schedules.index_by(&:template_key)
    @scheduled = @schedules_by_template.keys.to_set
    @notifications = SeoWorkflowNotification.joins(:seo_workflow_run)
      .where(seo_workflow_runs: { site_id: current_site.id, site_host: current_site.host })
      .order(created_at: :desc, id: :desc).limit(15).includes(:seo_workflow_run)
    results = current_site.seo_workflow_runs.where(site_host: current_site.host)
    @runs = results.order(created_at: :desc, id: :desc).limit(30)
    @latest_by_template = results.latest_by_template.index_by(&:template_key)
    @runs_needing_review = results.pending_review(@now).order(:updated_at, :id).limit(30)
  end

  def setup
    @templates = SeoWorkflows::Catalogue::TEMPLATES
    @guide = SeoWorkflows::SetupGuide.new(current_site, owner: workspace_owner?)
  end

  def evidence_preview
    key = params[:template]
    return head :not_found unless SeoWorkflows::Catalogue::PREVIEW_KEYS.include?(key)

    response.headers["Cache-Control"] = "no-store"
    @template = SeoWorkflows::Catalogue.fetch(key)
    now = Time.current
    @day = now.in_time_zone(current_site.time_zone).to_date
    @start = @template.period_start(@day)
    @rows = SeoWorkflows::Report.new(site: current_site, template: @template, day: @day, now: now).rows
  end

  def recover_competitor_evidence
    series_id = params[:series_id]
    series = Tracking::SerpEvidenceRecovery.available_series(current_site, feature: "P2").find { |candidate| candidate.id.to_s == series_id }
    return head :not_found unless series

    SeoCompetitorEvidenceJob.perform_later(current_site.id, series.id, current_user.id)
    redirect_to setup_seo_workflows_path(anchor: "P2"), notice: "Evidence recovery queued. Check the current-period preview after the worker finishes.", status: :see_other
  end

  def recover_local_services_evidence
    series = Tracking::SerpEvidenceRecovery.available_series(current_site, feature: "M4")
      .find { |candidate| candidate.id.to_s == params[:series_id] }
    return head :not_found unless series

    SeoLocalServicesEvidenceJob.perform_later(current_site.id, series.id, current_user.id)
    redirect_to setup_seo_workflows_path(anchor: "M4"),
      notice: "Local Services Ads evidence recovery queued.", status: :see_other
  end

  def local_services_capture
    @capture = SeoWorkflows::LocalServicesPanels.scope(current_site).find(params[:capture_id])
    @series = @capture.tracking_series
    @sample = @capture.evidence.fetch(Tracking::GoogleLocalServices::KEY)
  end

  def sample_ai_visibility
    SeoWorkflows::AiVisibilitySample.request(site: current_site, owner_id: current_user.id,
      engine: params[:engine], revision: params[:revision])
    redirect_to setup_seo_workflows_path(anchor: "M5"), notice: "AI sample queued. Its result will appear under M5.", status: :see_other
  rescue SeoWorkflows::AiVisibilitySample::Unavailable => error
    redirect_to setup_seo_workflows_path(anchor: "M5"), alert: error.message, status: :see_other
  end

  def request_maps_scan
    unless params[:approved] == "1"
      return redirect_to setup_seo_workflows_path(anchor: "M1"), alert: "Confirm the use of Local Falcon credits first.", status: :see_other
    end
    receipt = LocalFalcon::ScanCollection.request(site: current_site, owner_id: current_user.id,
      keyword_id: params[:keyword_id], size: params[:size], radius: params[:radius], revision: params[:revision])
    redirect_to source_snapshot_path(receipt), status: :see_other
  rescue LocalFalcon::ScanCollection::Unavailable => error
    redirect_to setup_seo_workflows_path(anchor: "M1"), alert: error.message, status: :see_other
  end

  def import_maps_grid
    snapshot = LocalFalcon::ScanCollection.import!(site: current_site, key: params[:report_key].to_s.strip)
    redirect_to source_snapshot_path(snapshot), notice: "The verified Google Maps grid is saved.", status: :see_other
  rescue LocalFalcon::ScanCollection::Unavailable, LocalFalcon::Client::Error => error
    redirect_to setup_seo_workflows_path(anchor: "M1"), alert: error.message, status: :see_other
  end

  def compare_landing_pages
    SeoWorkflows::PageComparison.request(site: current_site, owner_id: current_user.id,
      own_url: params[:own_page_url], competitor_url: params[:competitor_page_url])
    redirect_to setup_seo_workflows_path(anchor: "E4"), notice: "Page comparison saved. See the result under E4.", status: :see_other
  rescue SeoWorkflows::PageComparison::Unavailable => error
    redirect_to setup_seo_workflows_path(anchor: "E4"), alert: error.message, status: :see_other
  end

  def open_rollup_location
    run = current_site.seo_workflow_runs.where(site_host: current_site.host, template_key: "R3").find(params[:rollup_id])
    entry = SeoWorkflows::Rollup.visible_rows(current_site, run.result).pluck("rollup_location")
      .find { |row| row["report_id"].to_s == params[:report_id].to_s && row["report_id"] }
    raise ActiveRecord::RecordNotFound unless entry

    location = current_workspace.sites.where(host: entry.fetch("host"), seo_workflow_rollup_enabled: true).find(entry.fetch("id"))
    report = location.seo_workflow_runs.where(site_host: location.host, period_on: run.period_on, template_key: "R2",
      status: SeoWorkflows::Rollup::REPORT_STATUSES).find(entry.fetch("report_id"))
    select_current_site(location)
    redirect_to seo_workflow_path(report), status: :see_other
  end

  def show
    @collection = LocalSeoData::Collection.receipt(current_site, @run.template_key, @run.period_on)
    @collection = nil unless @collection&.metrics&.fetch("host", nil) == current_site.host
    if workspace_owner? && %w[E1 E2].include?(@run.template_key)
      @publication_connection = current_site.business_profile_connection
      @publications = BusinessProfilePublication.where(seo_workflow_run: @run).index_by(&:row_index)
    end
  end

  def competitor_capture
    @capture = SeoWorkflows::CompetitorPacks.scope(current_site).find(params[:capture_id])
    @series = @capture.tracking_series
    @sample = @capture.evidence.fetch(Tracking::GoogleLocalPack::KEY)
  end

  def run
    day = Time.current.in_time_zone(current_site.time_zone).to_date
    period = @template.period_on(day) || day
    existing = current_site.seo_workflow_runs.find_by(template_key: @template.key, site_host: current_site.host, period_on: period)
    if LocalSeoData::Collection.enabled?(current_site, @template.key) && (existing.nil? || existing.status == "missing_evidence")
      SeoWorkflowCollectionJob.perform_later(current_site.id, @template.key, period.iso8601, current_user.id)
      return redirect_to seo_workflows_path, notice: "Provider collection queued. Check Recent results after it finishes.", status: :see_other
    end

    if existing && @template.key == "R3"
      existing.refresh_rollup!
      return redirect_to seo_workflow_path(existing)
    end

    if existing&.status == "complete" && @template.key == "R1"
      existing.refresh_weekly_report!
      return redirect_to seo_workflow_path(existing)
    end

    record = existing && existing.status != "missing_evidence" ? existing :
      SeoWorkflowRun.generate!(site: current_site, template: @template, day: period)
    redirect_to seo_workflow_path(record), status: :see_other
  end

  def schedule
    return head :unprocessable_entity if @template.cadence == :on_demand

    case params[:enabled]
    when "1"
      current_site.seo_workflow_schedules.create_or_find_by!(template_key: @template.key)
    when "0"
      current_site.seo_workflow_schedules.where(template_key: @template.key).destroy_all
    else
      return head :unprocessable_entity
    end
    redirect_to seo_workflows_path, notice: "SEO task schedule saved.", status: :see_other
  end

  def rollup
    return head :unprocessable_entity unless %w[0 1].include?(params[:enabled])

    current_site.update!(seo_workflow_rollup_enabled: params[:enabled] == "1")
    redirect_to seo_workflows_path, notice: "Location rollup preference saved.", status: :see_other
  end

  def slack
    webhook = params[:webhook].to_s.strip
    return head :unprocessable_entity if webhook.present? && !SeoWorkflows::SlackWebhook.valid?(webhook)

    current_site.update!(seo_slack_webhook: webhook.presence, seo_slack_revision: webhook.present? ? SecureRandom.uuid : nil)
    redirect_to seo_workflows_path, status: :see_other, notice: webhook.present? ? "Slack alerts connected." : "Slack alerts disconnected."
  end

  def notifications
    preference = params[:enabled]
    return head :unprocessable_entity unless %w[0 1].include?(preference)
    return head :forbidden if preference == "1" && current_user.email_verified_at.blank?

    current_site.update!(seo_workflow_email_owner_id: current_user.id) if preference == "1"
    current_site.update!(seo_workflow_email_owner_id: nil) if preference == "0"
    redirect_to seo_workflows_path, notice: "Notification preference saved.", status: :see_other
  end

  def export_evidence
    response.headers["Cache-Control"] = "no-store"
    send_data JSON.pretty_generate(SeoWorkflows::EvidenceBundle.new(current_site).build),
      type: "application/json", filename: "searchdesk-seo-evidence.json", disposition: "attachment"
  end

  def download_brain_vault
    response.headers["Cache-Control"] = "private, no-store"
    host = ENV["APP_HOST"].presence || ENV["RENDER_EXTERNAL_HOSTNAME"].presence
    origin = host ? "#{ENV.fetch('APP_PROTOCOL', request.scheme)}://#{host}" : request.base_url
    archive = SeoWorkflows::BrainVaultDownload.build(current_site, origin: origin)
    send_data archive, filename: "#{current_site.host}-local-seo-brain.zip", type: "application/zip",
      disposition: "attachment"
  rescue SeoWorkflows::BrainVaultDownload::NoEvidence
    redirect_to seo_workflows_path(vault: "empty", anchor: "workflow-evidence"),
      alert: "Save an R1 weekly report or M1 Maps grid before downloading your vault."
  rescue SeoWorkflows::BrainVaultDownload::Unavailable
    Rails.logger.error("Searchdesk Local SEO Brain vault generation failed")
    render plain: "The vault could not be generated. Try downloading it again.", status: :service_unavailable
  end

  def import_evidence
    snapshot = SeoWorkflows::EvidenceImport.call(site: current_site, kind: params[:kind],
      observed_on: params[:observed_on], upload: params[:export])
    redirect_to source_snapshot_path(snapshot), notice: "Derived evidence saved.", status: :see_other
  rescue SeoWorkflows::EvidenceImport::InvalidExport => error
    redirect_to seo_workflows_path, alert: error.message, status: :see_other
  end

  def refresh_draft
    refreshed = @run.refresh_landing_page_draft!(user: current_user)
    notice = refreshed ? "Draft refreshed. Review the updated evidence and wording." : "No changes were made to the draft."
    redirect_to seo_workflow_path(@run), notice: notice, status: :see_other
  end

  def review
    if @run.review!(decision: params[:decision], user: current_user, revision: params[:revision])
      redirect_to seo_workflow_path(@run), notice: "Review decision saved.", status: :see_other
    else
      redirect_to seo_workflow_path(@run), alert: "This draft changed or can no longer be reviewed. Open the current version before making a decision.", status: :see_other
    end
  end

  def record_delivery
    if @run.record_delivery!(user: current_user)
      redirect_to seo_workflow_path(@run), notice: "Manual delivery recorded.", status: :see_other
    else
      redirect_to seo_workflow_path(@run), alert: "Approve this report before recording delivery.", status: :see_other
    end
  end

  def preview_delivery
    return head :unprocessable_entity unless params[:recipient].is_a?(String)

    delivery = SeoWorkflowReportDelivery.preview!(run: @run, user: current_user, recipient: params[:recipient])
    return head :conflict unless delivery

    redirect_to seo_workflow_path(@run), status: :see_other
  rescue ActiveRecord::RecordInvalid
    redirect_to seo_workflow_path(@run), alert: "Enter one valid email address.", status: :see_other
  end

  def confirm_delivery
    delivery = SeoWorkflowReportDelivery.find_by!(seo_workflow_run: @run, id: params[:delivery_id])
    return head :conflict unless delivery.confirm!(user: current_user)

    redirect_to seo_workflow_path(@run), notice: "Report queued for delivery.", status: :see_other
  end

  def cancel_delivery
    delivery = SeoWorkflowReportDelivery.find_by!(seo_workflow_run: @run, id: params[:delivery_id])
    return head :conflict unless delivery.cancel_preview!(user: current_user)

    redirect_to seo_workflow_path(@run), status: :see_other
  end

  def publish
    index = Integer(params[:row_index].to_s, 10, exception: false)
    BusinessProfilePublication.confirm!(run: @run, index: index, user: current_user, expected_grant: params[:grant])
    redirect_to seo_workflow_path(@run), status: :see_other
  rescue BusinessProfilePublication::NotEligible => error
    redirect_to seo_workflow_path(@run), status: :see_other, alert: error.message
  end

  private

  def load_template
    @template = SeoWorkflows::Catalogue::TEMPLATES[params[:template]]
    head :unprocessable_entity unless @template&.available?
  end

  def load_run
    @run = current_site.seo_workflow_runs.where(site_host: current_site.host).find(params[:id])
  end
end
