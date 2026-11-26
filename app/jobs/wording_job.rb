class WordingJob < ApplicationJob
  MAX_ATTEMPTS_PER_DAY = 3
  MAX_PENDING_AGE = 24.hours

  def perform(run_id)
    run = WordingRun.find_by(id: run_id)
    return unless run
    setting = run.wording_setting
    return unless reserve_attempt(setting, run)

    # The durable reservation prevents retrying an ambiguous POST. The second lock
    # orders dispatch against revocation, even when the revision changed after reservation.
    setting.with_lock do
      run.reload
      next unless run.status == "running" && setting.enabled? && setting.revision == run.revision
      next run.update!(status: "expired") if run.created_at < MAX_PENDING_AGE.ago
      next run.update!(status: "template") unless SeoSkills::WordingClient.configured?
      choice = wording_client.choose(setting.lines, model: run.model)
      run.update!(status: "selected", choice: choice)
    end
  rescue SeoSkills::WordingClient::Unavailable
    WordingRun.where(id: run_id, status: "running").update_all(status: "template", updated_at: Time.current)
  end

  private

  def wording_client
    SeoSkills::WordingClient.new
  end

  def reserve_attempt(setting, run)
    setting.with_lock do
      run.reload
      next false unless run.status == "pending"

      status = if !setting.enabled? || setting.revision != run.revision
        "superseded"
      elsif run.created_at < MAX_PENDING_AGE.ago
        "expired"
      elsif run.skill_version != SeoSkills::Registry.fetch("business_wording")[:version] || !SeoSkills::WordingClient.configured?
        "template"
      elsif setting.wording_runs.where(attempted_at: Time.current.utc.beginning_of_day..).count >= MAX_ATTEMPTS_PER_DAY
        "daily_limit"
      end
      if status
        run.update!(status: status)
        next false
      end

      run.update!(status: "running", attempted_at: Time.current, model: ENV.fetch("SEO_AI_MODEL"))
      true
    end
  end
end
