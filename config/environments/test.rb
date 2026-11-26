Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = false
  config.consider_all_requests_local = true
  config.action_dispatch.show_exceptions = :rescuable
  config.action_controller.allow_forgery_protection = false
  config.cache_store = :memory_store
  config.action_mailer.delivery_method = :test
  config.active_job.queue_adapter = :test
end
