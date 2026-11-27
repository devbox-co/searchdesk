class SeoWorkflowMailer < ActionMailer::Base
  default from: -> { ENV.fetch("MAIL_FROM", "SEO Workspace <accounts@localhost>") }

  def notification(notification, user)
    path = Rails.application.routes.url_helpers.seo_workflow_url(notification.seo_workflow_run_id,
      **Rails.application.config.action_mailer.default_url_options)
    mail(to: user.email, subject: "Searchdesk · #{notification.label}", content_type: "text/plain",
      body: "#{notification.label}. Sign in to Searchdesk and select the relevant site to open this task.\n\n#{path}\n")
  end
  def client_report(delivery)
    run = delivery.seo_workflow_run
    lines = run.result.map { |row| "#{row.fetch('source')}: #{row.fetch('text')}" }
    body = [run.template.name, "Reporting period through #{run.period_on}", *lines].join("\n\n")
    mail(to: delivery.recipient, subject: "Searchdesk · #{run.template.name}", content_type: "text/plain", body: body)
  end

end
