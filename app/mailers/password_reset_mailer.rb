class PasswordResetMailer < ActionMailer::Base
  default from: -> { ENV.fetch("MAIL_FROM", "SEO Workspace <accounts@localhost>") }

  def instructions(user)
    reset_url = Rails.application.routes.url_helpers.edit_password_reset_url(
      user.password_reset_token,
      **Rails.application.config.action_mailer.default_url_options
    )
    mail(to: user.email, subject: "Reset your SEO Workspace password",
      content_type: "text/plain",
      body: "Open this link within 20 minutes to choose a new password:\n\n#{reset_url}\n\nIf you did not request this, you can ignore this message.")
  end
end
