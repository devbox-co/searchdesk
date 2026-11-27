class SeoWorkflowNotification < ApplicationRecord
  belongs_to :seo_workflow_run
  belongs_to :recipient, class_name: "User", optional: true

  MESSAGES = {
    "complete" => "Result ready",
    "attention" => "SEO result needs attention",
    "awaiting_approval" => "Review requested",
    "reminder" => "Review reminder",
    "expired" => "Draft expired",
    "delivered" => "Delivery recorded",
    "published" => "Google publication recorded"
  }.freeze

  def self.record!(run:, kind:)
    recipient_id = run.site.seo_workflow_email_owner_id
    create_or_find_by!(seo_workflow_run: run, kind: kind) do |notification|
      notification.recipient_id = recipient_id
      notification.email_status = "pending" if recipient_id
      if run.site.seo_slack_revision
        notification.slack_revision = run.site.seo_slack_revision
        notification.slack_status = "pending"
      end
    end
  end

  def label = MESSAGES.fetch(kind)

  def deliver_email!(now: Time.current)
    user = with_lock do
      next unless email_status == "pending"

      user = eligible_recipient
      # Reserve before SMTP. A lost acknowledgement must not cause a duplicate.
      update!(email_status: user ? "sending" : "cancelled", email_attempted_at: now)
      user
    end
    return unless user

    SeoWorkflowMailer.notification(self, user).deliver_now
    update!(email_status: "sent", email_sent_at: Time.current)
  rescue StandardError => error
    raise unless email_status == "sending"

    update!(email_status: "uncertain")
    Rails.logger.warn("SEO workflow notification #{id} could not confirm delivery (#{error.class})")
  end

  def deliver_slack!(now: Time.current, client: SeoWorkflows::SlackWebhook.new)
    webhook = with_lock do
      next unless slack_status == "pending"

      site = seo_workflow_run.site
      valid = site.seo_slack_revision == slack_revision && site.host == seo_workflow_run.site_host &&
        timely?(now) && site.seo_slack_webhook.present?
      update!(slack_status: valid ? "sending" : "cancelled", slack_attempted_at: now)
      site.seo_slack_webhook if valid
    end
    return unless webhook

    path = Rails.application.routes.url_helpers.seo_workflow_url(seo_workflow_run_id,
      **Rails.application.config.action_mailer.default_url_options)
    client.deliver!(webhook: webhook, label: label, path: path)
    update!(slack_status: "sent")
  rescue StandardError => error
    raise unless slack_status == "sending"

    update!(slack_status: "uncertain")
    Rails.logger.warn("SEO workflow Slack event #{id} could not confirm delivery (#{error.class})")
  end

  private

  def timely?(now)
    !%w[awaiting_approval reminder].include?(kind) || seo_workflow_run.effective_status(now: now) == "awaiting_approval"
  end

  def eligible_recipient
    run = seo_workflow_run
    site = run.site
    return unless recipient_id && site.seo_workflow_email_owner_id == recipient_id && site.host == run.site_host
    return if %w[awaiting_approval reminder].include?(kind) && run.effective_status != "awaiting_approval"

    user = User.where.not(email_verified_at: nil).find_by(id: recipient_id)
    user if user && Membership.exists?(workspace_id: site.workspace_id, user: user, role: "owner")
  end
end
