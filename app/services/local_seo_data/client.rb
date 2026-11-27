require "net/http"

module LocalSeoData
  class Client
    class Unavailable < StandardError; end

    BASE = "https://api.localseodata.com"
    MAX_BYTES = 2.megabytes
    LOCAL_AUDIT = "/v1/audit/local"
    AUDIT_ID = /\Aaudit_[A-Za-z0-9_-]{1,100}\z/
    ENDPOINTS = { "M2" => "/v1/business/reviews", "M3" => "/v1/business/profile", "M4" => "/v1/serp/lsa", "E3" => "/v1/audit/citation" }.freeze

    def collect(task, payload)
      response = request_json(ENDPOINTS.fetch(task), payload)
      task == "M4" ? response : data_from(response)
    end

    def submit_prospect(business_name:, market:)
      data = data_from(request_json(LOCAL_AUDIT, { business_name: business_name, location: market }))
      id = data["job_id"]
      raise Unavailable unless data["status"] == "pending" && id.is_a?(String) && AUDIT_ID.match?(id)

      id
    end

    def poll_prospect(id)
      raise Unavailable unless id.is_a?(String) && AUDIT_ID.match?(id)

      data = data_from(request_json("#{LOCAL_AUDIT}/status/#{id}"))
      raise Unavailable unless data["job_id"] == id && %w[pending complete failed].include?(data["status"])

      data
    end

    private

    def request_json(path, payload = nil)
      uri = URI(BASE + path)
      request = payload ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{ENV.fetch('LOCALSEODATA_API_KEY')}"
      if payload
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(payload)
      end

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 120
      http.write_timeout = 10
      http.max_retries = 0

      raw = +""
      http.start do |session|
        session.request(request) do |response|
          raise Unavailable unless response.is_a?(Net::HTTPSuccess)

          response.read_body do |chunk|
            raise Unavailable if raw.bytesize + chunk.bytesize > MAX_BYTES

            raw << chunk
          end
        end
      end
      result = JSON.parse(raw)
      raise Unavailable unless result.is_a?(Hash) && result["status"] == "success"

      result
    rescue IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError, JSON::ParserError
      raise Unavailable
    end
    def data_from(response)
      data = response["data"]
      raise Unavailable unless data.is_a?(Hash)

      data
    end
  end
end
