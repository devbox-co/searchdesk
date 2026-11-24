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

    def self.enabled?
      ENV["DATAFORSEO_ENABLED"] == "true" && ENV["DATAFORSEO_LOGIN"].present? && ENV["DATAFORSEO_PASSWORD"].present?
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

    def submit(slot)
      config = slot.tracking_series.settings
      payload = {
        keyword: config.fetch("keyword"), location_code: config.fetch("location_code"),
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

    def validate_id(value)
      raise ScopeError, "Invalid provider task ID" unless value.is_a?(String) && value.match?(/\A[\da-f-]{36}\z/i)
      value
    end

    def tag(slot)
      slot.attempt_key || raise(ScopeError, "Missing correlation key")
    end

    def request(verb, path, body = nil, max_bytes: MAX_BYTES)
      raise Unavailable, "Provider is disabled" unless self.class.enabled?
      http = Net::HTTP.new(HOST, 443)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 20
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
