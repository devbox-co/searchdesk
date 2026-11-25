class AssistantSettingsController < ApplicationController
  before_action :no_store
  before_action :require_workspace_owner
  before_action :load_configuration
  before_action :require_local_setup, only: %i[update_connection test_connection]

  def show
    if params[:preview] == "1"
      @preview = AiAssistant::Evidence.build(site: current_site, setting: @setting, question: nil,
        day: Time.current.in_time_zone(current_site.time_zone).to_date, kind: "brief")
    end
  end

  def update_connection
    inputs = params.require(:ai_connection).permit(:project_label, :monthly_budget_usd, :api_key)
    return invalid("Enter a label so you can recognise the billing project.") if inputs[:project_label].blank?
    amount = inputs[:monthly_budget_usd].to_s.strip
    unless amount.match?(/\A\d{1,6}(?:\.\d{1,2})?\z/)
      return invalid("Enter the monthly allowance in US dollars, with up to two decimal places.")
    end
    current_workspace.with_lock do
      @connection = AiConnection.find_or_initialize_by(workspace: current_workspace)
      @connection.assign_attributes(project_label: inputs[:project_label].to_s.strip, monthly_budget_cents: (amount.to_d * 100).to_i)
      @connection.api_key = inputs[:api_key].strip if inputs[:api_key].present?
      return invalid("Enter your OpenAI project API key.") unless @connection.configured?
      @connection.save!
    end
    redirect_to assistant_settings_path, notice: "OpenAI account settings saved.", status: :see_other
  rescue ActiveRecord::RecordInvalid => error
    invalid(error.record.errors.full_messages.to_sentence)
  end

  def update
    inputs = params.require(:ai_setting).permit(:enabled, :managers_enabled, :daily_brief_enabled,
      :share_google, :share_maps, :share_semrush, :services, :priorities, :enquiry_definition)
    current_site.with_lock do
      @setting = AiSetting.find_or_initialize_by(site: current_site)
      @setting.update!(inputs)
    end
    redirect_to assistant_settings_path(anchor: "site-settings"), notice: "Assistant settings saved for #{current_site.name}.", status: :see_other
  rescue ActiveRecord::RecordInvalid => error
    invalid(error.record.errors.full_messages.to_sentence)
  end

  def test_connection
    unless @connection.configured? && @connection.monthly_budget_cents.positive?
      return redirect_to assistant_settings_path, alert: "Save a key and a positive allowance before testing.", status: :see_other
    end
    key = params[:request_key].to_s
    return head :unprocessable_entity unless key.match?(/\A[0-9a-f-]{36}\z/i)
    run = AiRun.request!(site: current_site, user: current_user, kind: "test", request_key: key)
    AiRunJob.perform_later(run.id) if run.previously_new_record?
    redirect_to assistant_run_path(run), status: :see_other
  rescue ActiveRecord::RecordInvalid => error
    redirect_to assistant_settings_path, alert: error.record.errors.full_messages.to_sentence, status: :see_other
  end

  def disconnect
    @connection.disconnect! if @connection.persisted?
    redirect_to assistant_settings_path, notice: "Disconnected OpenAI for this workspace.", status: :see_other
  end

  private

  def load_configuration
    @connection = AiConnection.find_or_initialize_by(workspace: current_workspace)
    @setting = AiSetting.find_or_initialize_by(site: current_site)
  end

  def require_local_setup
    head :forbidden unless AiConnection.owner_controlled_installation?
  end

  def invalid(message)
    flash.now[:alert] = message
    render :show, status: :unprocessable_entity
  end
end
