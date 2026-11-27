class SeoWorkflowNotificationsJob < ApplicationJob
  def perform
    now = Time.current
    BusinessProfilePublication.where(status: "sending", attempted_at: ..(now - 1.hour)).update_all(status: "uncertain")
    BusinessProfilePublication.where(attempted_at: ..(now - 29.days)).where.not(provider_reference: nil)
      .update_all(provider_reference: nil)
    SeoWorkflowRun.where(status: "awaiting_approval", updated_at: ..(now - 48.hours))
      .find_each { |run| run.check_review_window!(now: now) }
    SeoWorkflowNotification.where(email_status: "sending", email_attempted_at: ..(now - 1.hour))
      .update_all(email_status: "uncertain")
    SeoWorkflowReportDelivery.where(status: "sending", attempted_at: ..(now - 1.hour)).update_all(status: "uncertain")
    SeoWorkflowReportDelivery.where(status: "pending").find_each { |delivery| delivery.send_report!(now: now) }
    SeoWorkflowNotification.where(email_status: "pending").find_each { |event| event.deliver_email!(now: now) }
    SeoWorkflowNotification.where(slack_status: "sending", slack_attempted_at: ..(now - 1.hour))
      .update_all(slack_status: "uncertain")
    SeoWorkflowNotification.where(slack_status: "pending").find_each { |event| event.deliver_slack!(now: now) }
  end
end
