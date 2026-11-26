class WordingSettingsController < ApplicationController
  before_action :require_workspace_owner
  def show
    @setting = WordingSetting.find_or_initialize_by(site: current_site)
  end

  def update
    attributes = params.require(:wording_setting).permit(:enabled, :phrases)
    enabled = ActiveModel::Type::Boolean.new.cast(attributes[:enabled])
    queued = nil
    current_site.with_lock do
      @setting = WordingSetting.find_or_initialize_by(site: current_site)
      @setting.assign_attributes(enabled: enabled, phrases: enabled ? attributes[:phrases].to_s.strip : "")
      if @setting.new_record? || @setting.changed?
        @setting.revision = SecureRandom.uuid
        @setting.save!
        @setting.wording_runs.where(status: %w[pending running selected]).update_all(status: "superseded", choice: nil, updated_at: Time.current)
        if enabled
          version = SeoSkills::Registry.fetch("business_wording")[:version]
          queued = @setting.wording_runs.create!(revision: @setting.revision, skill_version: version)
        end
      end
    end
    WordingJob.perform_later(queued.id) if queued
    redirect_to wording_setting_path, notice: "Wording preferences saved."
  rescue ActiveRecord::RecordInvalid
    render :show, status: :unprocessable_entity
  end
end
