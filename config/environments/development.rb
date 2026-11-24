Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.action_mailer.delivery_method = :file
  config.action_mailer.file_settings = { location: Rails.root.join("tmp", "mail") }
end
