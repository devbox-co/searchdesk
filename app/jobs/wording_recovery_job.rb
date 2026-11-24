class WordingRecoveryJob < ApplicationJob
  def perform
    WordingRun.where(status: "running", attempted_at: ...10.minutes.ago).update_all(status: "template", updated_at: Time.current)
    WordingRun.where(status: "pending", created_at: ...1.minute.ago).find_each { |run| WordingJob.perform_later(run.id) }
  end
end
