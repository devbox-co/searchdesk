require_relative "boot"
require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "active_job/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"
require "rails/test_unit/railtie"

Bundler.require(*Rails.groups)
module SeoWorkspace
  class Application < Rails::Application
    config.load_defaults 8.1
    config.active_job.queue_adapter = :solid_queue
    config.time_zone = "UTC"
    config.action_mailer.default_url_options = {
      host: ENV.fetch("APP_HOST") { ENV.fetch("RENDER_EXTERNAL_HOSTNAME", "localhost:3038") },
      protocol: ENV.fetch("APP_PROTOCOL", "http")
    }
    config.generators.system_tests = nil
    config.active_record.schema_format = :ruby
  end
end
