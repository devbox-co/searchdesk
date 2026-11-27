require "net/http"
require "time"

module Tracking
  class DataForSeo
    class Unavailable < StandardError; end
    class Rejected < StandardError; end
    class ScopeError < StandardError; end
    HOST = "api.dataforseo.com"
    PREFIX = "/v3/serp/google/organic"
    MAX_BYTES = 4 * 1024 * 1024
    PREMIUM_OPERATOR = /(?:allinanchor|allintext|allintitle|allinurl|cache|define|filetype|id|inanchor|info|intext|intitle|inurl|link|site):/i

    def self.enabled?
      ENV["DATAFORSEO_ENABLED"] == "true" && ENV["DATAFORSEO_LOGIN"].present? && ENV["DATAFORSEO_PASSWORD"].present?
    end

    def self.daily_task_limit
      configured_limit("DATAFORSEO_DAILY_TASK_LIMIT", 100, 2000)
    end

    def self.rolling_task_limit
      configured_limit("DATAFORSEO_31_DAY_TASK_LIMIT", daily_task_limit * 31, 62_000)
    end

    def self.series_allowed?(id)
      configured = ENV["DATAFORSEO_ALLOWED_SERIES_IDS"]
      return true if configured.nil?

      ids = configured.split(",", -1).map(&:strip)
      ids.all? { |value| value.match?(/\A[1-9]\d{0,18}\z/) && value.to_i <= 9_223_372_036_854_775_807 } && ids.include?(id.to_s)
    end

    def self.configured_limit(key, fallback, maximum)
      value = Integer(ENV.fetch(key, fallback).to_s, 10, exception: false)
      (value || 0).clamp(0, maximum)
    end
    private_class_method :configured_limit

    def business_profile(place_id:, location_code:)
      payload = { keyword: "place_id:#{place_id}", location_code: location_code, language_code: "en" }
      tasks = request(:post, "/v3/business_data/google/my_business_info/live", [payload]).fetch("tasks")
      task = tasks.sole
      unless task["status_code"] == 20000 && task.fetch("data").slice("keyword", "location_code", "language_code") == payload.stringify_keys
        raise Unavailable, "Provider response did not match the requested profile"
      end

      result = task.fetch("result").sole
      result.fetch("items").select { |item| item["type"] == "google_business_info" && item["place_id"] == place_id }.sole
    rescue KeyError, TypeError, NoMethodError, ActiveSupport::EnumerableCoreExt::SoleItemExpectedError
      raise Unavailable, "Provider did not return a unique matching profile"
    end

    REVIEWS_PATH = "/v3/business_data/google/reviews"

    def submit_reviews(place_id:, location_code:, depth:, tag:)
      payload = review_request(place_id, location_code, depth, tag)
      task = request(:post, "#{REVIEWS_PATH}/task_post", [payload]).fetch("tasks").sole
      unless task["status_code"] == 20100
        raise Unavailable, "Provider did not accept the review task"
      end

      validate_id(task.fetch("id"))
    rescue KeyError, TypeError, NoMethodError, ScopeError, ActiveSupport::EnumerableCoreExt::SoleItemExpectedError
      raise Unavailable, "Provider submission could not be confirmed"
    end

    def poll_reviews(id:, place_id:, location_code:, depth:, tag:)
      task = request(:get, "#{REVIEWS_PATH}/task_get/#{validate_id(id)}").fetch("tasks").sole
      raise Unavailable, "Unexpected review task ID" unless task["id"] == id
      return if [20100, 40601, 40602].include?(task["status_code"])

      payload = review_request(place_id, location_code, depth, tag).except(:priority).stringify_keys
      result = task.fetch("result").sole if task["status_code"] == 20000
      unless result && task.fetch("data").slice(*payload.keys) == payload &&
          result["place_id"] == place_id && result["type"] == "google_reviews" &&
          result["location_code"] == location_code && result["language_code"] == "en"
        raise Rejected, "Provider did not return the requested review profile"
      end

      result
    rescue KeyError, TypeError, NoMethodError, ScopeError, ActiveSupport::EnumerableCoreExt::SoleItemExpectedError
      raise Rejected, "Provider returned incomplete review evidence"
    end

    def locations(country)
      raise ScopeError, "Invalid country" unless country.match?(/\A[A-Z]{2}\z/)
      raise Unavailable, "Provider is disabled" unless self.class.enabled?
      # Country-specific catalogue requests never create a SERP task. Bound CPU, response size and cache life.
      Rails.cache.fetch(["tracking_country_locations_v1", country], expires_in: 24.hours) do
        reply = request(:get, "/v3/serp/google/locations/#{country.downcase}", max_bytes: 32 * 1024 * 1024)
        task = reply.fetch("tasks").fetch(0)
        raise Unavailable, "Catalogue temporarily unavailable" unless task["status_code"] == 20000
        rows = task.fetch("result")
        raise ScopeError, "Location catalogue too large" unless rows.is_a?(Array) && rows.size <= 180_000
        rows.filter_map { |item| item.slice("location_code", "country_iso_code", "location_name") if item.is_a?(Hash) }
      end
    end

    def google_overview(keyword:, location_code:)
      if URI::DEFAULT_PARSER.unescape(keyword).scrub.match?(PREMIUM_OPERATOR)
        raise Unavailable, "This search operator is outside the approved Google sample budget"
      end

      input = { keyword: keyword, location_code: location_code, language_code: "en", device: "desktop", os: "windows",
        depth: 10, max_crawl_pages: 1, load_async_ai_overview: true }
      task = request(:post, "#{PREFIX}/live/advanced", [input], read_timeout: 45).fetch("tasks").sole
      result = task.fetch("result").sole
      scope = input.slice(:keyword, :location_code, :language_code, :device, :os, :load_async_ai_overview).stringify_keys
      unless task["status_code"] == 20000 && task.fetch("data").slice(*scope.keys) == scope &&
          result.slice("keyword", "location_code", "language_code") == scope.slice("keyword", "location_code", "language_code") &&
          result["items"].is_a?(Array) && result["items"].size.between?(1, 500) && result["items"].all?(Hash)
        raise Unavailable, "Provider response did not match the requested search"
      end

      [validate_id(task["id"]), result]
    rescue KeyError, TypeError, NoMethodError, ScopeError, ActiveSupport::EnumerableCoreExt::SoleItemExpectedError
      raise Unavailable, "Provider returned incomplete Google search evidence"
    end

    def llm_response(engine:, model:, country:, prompt:)
      provider_engine = { "gemini" => "gemini", "perplexity" => "perplexity", "chatgpt" => "chat_gpt" }.fetch(engine)
      payload = { model_name: model, user_prompt: "Market: #{country}. #{prompt}", max_output_tokens: 200 }
      payload[:web_search] = true unless engine == "perplexity"
      payload[:web_search_country_iso_code] = country unless engine == "gemini"
      payload[:force_web_search] = true if engine == "chatgpt"

      timeout = engine == "chatgpt" ? 125 : 20
      task = request(:post, "/v3/ai_optimization/#{provider_engine}/llm_responses/live", [payload], read_timeout: timeout)
        .fetch("tasks").sole
      result = task.fetch("result").sole
      returned_model = result["model_name"]
      same_model = returned_model == model || (engine == "chatgpt" &&
        returned_model.to_s.match?(/\A#{Regexp.escape(model)}-\d{4}-\d{2}-\d{2}\z/))
      unless task["status_code"] == 20000 && task.dig("data", "se") == provider_engine &&
          task.dig("data", "user_prompt") == payload[:user_prompt] &&
          (engine == "gemini" || task.dig("data", "web_search_country_iso_code") == country) &&
          same_model && result["web_search"] == true && result["items"].is_a?(Array)
        raise Unavailable, "Provider response did not match the requested sample"
      end

      [validate_id(task["id"]), result]
    rescue KeyError, TypeError, NoMethodError, ScopeError, ActiveSupport::EnumerableCoreExt::SoleItemExpectedError
      raise Unavailable, "Provider returned incomplete sample data"
    end

    def submit(slot)
      config = slot.tracking_series.settings
      keyword = config.fetch("keyword")
      # The provider decodes percent escapes, then charges five times its rate for search operators.
      if URI::DEFAULT_PARSER.unescape(keyword).scrub.match?(PREMIUM_OPERATOR)
        raise Rejected, "This search operator is outside the standard-price rank collection budget"
      end
      payload = {
        keyword: keyword, location_code: config.fetch("location_code"),
        language_code: config.fetch("language"), device: config.fetch("device"), os: config.fetch("os"),
        depth: 30, max_crawl_pages: 3, priority: 1, tag: tag(slot)
      }
      response = request(:post, "#{PREFIX}/task_post", [payload])
      task = response.fetch("tasks").first
      raise Rejected, "Provider declined the task" unless task.fetch("status_code") == 20100
      validate_id(task.fetch("id"))
    end

    def recover(slot)
      response = request(:get, "#{PREFIX}/tasks_ready")
      matches = response.fetch("tasks").flat_map { |task| Array(task["result"]) }.select { |entry| entry["tag"] == tag(slot) }
      validate_id(matches.first.fetch("id")) if matches.length == 1
    end

    def poll(slot)
      id = validate_id(slot.task_id)
      response = request(:get, "#{PREFIX}/task_get/advanced/#{id}")
      task = response.fetch("tasks").first
      return nil if [20100, 40601, 40602].include?(task.fetch("status_code"))
      raise Rejected, "Provider could not return this task" unless task.fetch("status_code") == 20000
      raise ScopeError, "Unexpected task ID" unless task.fetch("id") == id
      data = task.fetch("data")
      config = slot.tracking_series.settings
      result = task.fetch("result").fetch(0)
      correct_scope = result["keyword"] == config.fetch("keyword") &&
        result["location_code"] == config.fetch("location_code") && result["language_code"] == config.fetch("language") &&
        data["device"] == config.fetch("device") && data["os"] == config.fetch("os") &&
        data["se"] == "google" && data["se_type"] == "organic" && data["tag"] == tag(slot)
      raise ScopeError, "Provider returned different tracking settings" unless correct_scope
      stamp = result.fetch("datetime")
      raise ScopeError, "Provider capture time lacks an offset" unless stamp.match?(/(?:Z|[+-]\d\d:\d\d)\z/i)
      { captured_at: Time.parse(stamp), items: result.fetch("items"), reference: id,
        metadata: { "source_label" => "DataForSEO Google organic", "result_domain" => result["se_domain"] } }
    rescue IndexError, KeyError, TypeError, ArgumentError
      raise ScopeError, "Provider returned incomplete or invalid evidence"
    end

    private

    def review_request(place_id, location_code, depth, tag)
      { keyword: "place_id:#{place_id}", location_code: location_code, language_code: "en",
        depth: depth, sort_by: "newest", priority: 1, tag: tag }
    end

    def validate_id(value)
      raise ScopeError, "Invalid provider task ID" unless value.is_a?(String) && value.match?(/\A[\da-f-]{36}\z/i)
      value
    end

    def tag(slot)
      slot.attempt_key || raise(ScopeError, "Missing correlation key")
    end

    def request(verb, path, body = nil, max_bytes: MAX_BYTES, read_timeout: 20)
      raise Unavailable, "Provider is disabled" unless self.class.enabled?
      http = Net::HTTP.new(HOST, 443)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = read_timeout
      http.write_timeout = 10
      http.max_retries = 0
      req = verb == :post ? Net::HTTP::Post.new(path) : Net::HTTP::Get.new(path)
      req.basic_auth(ENV.fetch("DATAFORSEO_LOGIN"), ENV.fetch("DATAFORSEO_PASSWORD"))
      req.content_type = "application/json"
      req.body = JSON.generate(body) if body
      json = +""
      http.start do |session|
        session.request(req) do |res|
          raise Unavailable, "Provider HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
          res.read_body do |part|
            raise Unavailable, "Provider response exceeded the read limit" if json.bytesize + part.bytesize > max_bytes
            json << part
          end
        end
      end
      decoded = JSON.parse(json)
      raise Unavailable, "Provider response unavailable" unless decoded["status_code"] == 20000
      decoded
    rescue IOError, SystemCallError, Timeout::Error, JSON::ParserError, OpenSSL::SSL::SSLError, EOFError
      raise Unavailable, "Provider request could not be confirmed"
    end
  end
end
