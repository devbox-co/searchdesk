class EmailVerificationMailer < ActionMailer::Base
  default from: -> { ENV.fetch("MAIL_FROM", "SEO Workspace <accounts@localhost>") }

  def instructions(user)
    verify_url = Rails.application.routes.url_helpers.verify_email_url(
      user.generate_token_for(:email_verification),
      **Rails.application.config.action_mailer.default_url_options
    )
    mail(to: user.email, subject: "Verify your SEO Workspace email",
      content_type: "text/plain",
      body: "Sign in to your account and open this link within 24 hours to verify your email address:\n\n#{verify_url}\n\nIf you did not request this, you can ignore this message.")
  end
end
