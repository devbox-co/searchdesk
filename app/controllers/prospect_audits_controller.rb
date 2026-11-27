class ProspectAuditsController < ApplicationController
  before_action :require_workspace_owner
  before_action -> { response.headers["Cache-Control"] = "no-store" }

  def index
    @audits = audits.order(created_at: :desc).limit(30)
  end

  def new
    @audit = audits.build
  end

  def create
    input = params.expect(prospect_audit: %i[target_host business_name market keyword provider])
    @audit = ProspectAudit.request_for(site: current_site, user: current_user,
      attributes: input.except(:provider).to_h, provider: input[:provider] == "1")
    if @audit.persisted?
      if @audit.website_status == "queued"
        ProspectAuditJob.perform_later(@audit.id)
      elsif @audit.provider_status == "queued" && %w[complete partial failed].include?(@audit.website_status)
        ProspectAuditProviderJob.perform_later(@audit.id)
      end
      redirect_to prospect_audit_path(@audit), status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordInvalid => error
    @audit = error.record
    render :new, status: :unprocessable_entity
  end

  def show
    @audit = audits.find(params[:id])
  end

  private

  def audits
    current_site.prospect_audits.where(site_host: current_site.host)
  end
end
