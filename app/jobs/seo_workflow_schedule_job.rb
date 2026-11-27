class SeoWorkflowScheduleJob < ApplicationJob
  def perform
    LocalSeoData::DataForSeoReviews.poll_pending
    now = Time.current
    SeoWorkflowSchedule.where.not(template_key: "R1").find_each { |schedule| schedule.run_due!(now: now) }
    SeoWorkflowSchedule.where(template_key: "R1").find_each { |schedule| schedule.run_due!(now: now) }
  end
end
