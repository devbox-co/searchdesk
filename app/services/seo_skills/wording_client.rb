require "net/http"

module SeoSkills
  class WordingClient
    class Unavailable < StandardError; end
    ENDPOINT = URI("https://api.anthropic.com/v1/messages")
    MAX_RESPONSE_BYTES = 16_384
    REQUEST_DEADLINE_SECONDS = 24

    def self.configured?
      ENV["ANTHROPIC_API_KEY"].present? && ENV["SEO_AI_MODEL"].present?
    end

    def choose(lines, model:)
      raise Unavailable unless self.class.configured?
      request = Net::HTTP::Post.new(ENDPOINT)
      request["Content-Type"] = "application/json"
      request["x-api-key"] = ENV.fetch("ANTHROPIC_API_KEY")
      request["anthropic-version"] = "2023-06-01"
      request.body = { model: model, max_tokens: 64, system: Registry.fetch("business_wording")[:contents],
        messages: [{ role: "user", content: JSON.generate(lines) }] }.to_json
      http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
      http.use_ssl = true
      http.open_timeout = 4
      http.write_timeout = 5
      http.read_timeout = 15
      http.max_retries = 0
      body = +""
      Timeout.timeout(REQUEST_DEADLINE_SECONDS) do
        http.start do |connection|
          connection.request(request) do |response|
            raise Unavailable unless response.is_a?(Net::HTTPSuccess)
            response.read_body do |chunk|
              raise Unavailable if body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES
              body << chunk
            end
          end
        end
      end
      self.class.parse(body, lines.size)
    rescue IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError
      raise Unavailable
    end

    def self.parse(body, count)
      message = JSON.parse(body)
      raise Unavailable unless message.is_a?(Hash) && message["stop_reason"] == "end_turn"
      blocks = message["content"]
      raise Unavailable unless blocks.is_a?(Array) && blocks.size == 1
      block = blocks.first
      raise Unavailable unless block.is_a?(Hash) && block["type"] == "text" && block["text"].is_a?(String)
      answer = JSON.parse(block["text"])
      raise Unavailable unless answer.is_a?(Hash) && answer.keys == ["choice"]
      choice = answer["choice"]
      raise Unavailable unless choice.is_a?(Integer) && choice.between?(1, count)
      choice
    rescue JSON::ParserError
      raise Unavailable
    end
  end
end
