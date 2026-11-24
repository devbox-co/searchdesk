ENV["RAILS_ENV"] = "test"
require_relative "../config/environment"
require "rails/test_help"

class ActionDispatch::IntegrationTest
  # Each test models an independent browser timeline. Keep rate limiting active
  # inside each test while avoiding state leaking from an earlier scenario.
  setup { Rails.cache.clear }
end
