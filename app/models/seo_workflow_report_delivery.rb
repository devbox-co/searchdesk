class SeoWorkflowReportDelivery < ApplicationRecord
  belongs_to :seo_workflow_run
  belongs_to :requested_by, class_name: "User", optional: true
  encrypts :recipient

  normalizes :recipient, with: ->(email) { email.to_s.strip }
  validates :recipient, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }, length: { maximum: 254 }

  def self.enabled_for?(user)
    ENV["SEO_WORKFLOW_CLIENT_EMAIL_ENABLED"] == "true" && user&.email_verified_at.present? &&
      %i[smtp test].include?(ActionMailer::Base.delivery_method)
  end

  def self.preview!(run:, user:, recipient:)
    run.with_lock do
      next unless enabled_for?(user) && run.approved_for_delivery_by?(user) && !run.report_delivery

      run.create_report_delivery!(requested_by: user, recipient: recipient)
    end
  end

  def confirm!(user:)
    with_lock do
      next false unless status == "preview" && requested_by_id == user.id && self.class.enabled_for?(user) &&
        seo_workflow_run.approved_for_delivery_by?(user)

      update!(status: "pending")
    end
  end

  def cancel_preview!(user:)
    with_lock do
      next false unless %w[preview cancelled].include?(status) && seo_workflow_run.approved_for_delivery_by?(user)

      destroy!
    end
  end

  def send_report!(now: Time.current)
    reserved = with_lock do
      next false unless status == "pending"

      authorised = self.class.enabled_for?(requested_by) && seo_workflow_run.approved_for_delivery_by?(requested_by)
      update!(status: authorised ? "sending" : "cancelled", attempted_at: now)
      authorised
    end
    return unless reserved

    SeoWorkflowMailer.client_report(self).deliver_now
    transaction do
      sent = Time.current
      update!(status: "sent", sent_at: sent)
      seo_workflow_run.update!(status: "delivered", delivered_by: requested_by, delivered_at: sent)
    end
  rescue StandardError => error
    raise unless reserved

    update!(status: "uncertain")
    Rails.logger.warn("SEO workflow report delivery #{id} could not confirm delivery (#{error.class})")
  end
end
