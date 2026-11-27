Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.action_controller.perform_caching = true
  config.cache_store = :memory_store
  config.public_file_server.enabled = true
  config.force_ssl = ENV["APP_PROTOCOL"] == "https"
  config.assume_ssl = config.force_ssl
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }
  config.logger = ActiveSupport::TaggedLogging.logger($stdout)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.silence_healthcheck_path = %r{\A/(?:up\z|password_resets/[^/]+(?:/edit)?\z|email_verification/[^/]+\z|search_console/callback\z|business_profile/callback\z)}
  config.active_record.dump_schema_after_migration = false
  config.action_mailer.delivery_method = ENV["SMTP_HOST"].present? ? :smtp : :file
  config.action_mailer.file_settings = { location: Rails.root.join("tmp", "mail") }
  if ENV["SMTP_HOST"].present?
    config.action_mailer.smtp_settings = {
      address: ENV["SMTP_HOST"], port: ENV.fetch("SMTP_PORT", 587).to_i,
      user_name: ENV["SMTP_USER"], password: ENV["SMTP_PASSWORD"],
      authentication: ENV["SMTP_USER"].present? ? :plain : nil, enable_starttls_auto: true
    }.compact
  end
end
