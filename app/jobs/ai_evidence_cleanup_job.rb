class AiEvidenceCleanupJob < ApplicationJob
  def perform
    AiSetting.includes(:site).find_each do |setting|
      AiRun.purge_hidden_for!(site: setting.site, setting: setting)
    end
  end
end
