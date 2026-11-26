require "net/http"
require "timeout"

module AiAssistant
  class OpenaiClient
    MODEL = "gpt-6-luna"
    TARIFF_VERSION = "gpt-6-luna-standard-short-2026-11-25"
    ENDPOINT = URI("https://api.openai.com/v1/responses").freeze
    MAX_OUTPUT = 1000
    MAX_BYTES = 32_000
    MAX_RESPONSE_BYTES = 128_000
    QUOTA_CODES = %w[insufficient_quota billing_hard_limit_reached credit_balance_exhausted
      organization_spend_limit_exceeded project_spend_limit_exceeded organization_usage_limit_exceeded].freeze
    Prepared = Data.define(:json, :facts, :reservation_microusd, :playbook_keys)
    Response = Data.define(:selection, :input_tokens, :output_tokens, :actual_microusd, :request_id)

    class Error < StandardError
      attr_reader :code, :charge_uncertain, :request_id

      def initialize(code, charge_uncertain: true, request_id: nil)
        @code, @charge_uncertain, @request_id = code, charge_uncertain, request_id
        super(code)
      end
    end

    def self.prepare(kind:, question:, evidence:, previous: nil)
      facts = evidence.fetch("facts").dup
      item = {
        type: "object", additionalProperties: false, required: %w[fact_ids next_check],
        properties: {
          fact_ids: { type: "array", items: { type: "string" }, minItems: 1, maxItems: 3 },
          next_check: { type: "string", enum: Recipe::CHECKS.keys }
        }
      }
      schema = { type: "object", additionalProperties: false, required: ["findings"],
        properties: { findings: { type: "array", items: item, maxItems: 3 } } }
      loop do
        playbooks = Playbooks.for_request(kind:, question:, facts:)
        instructions = [Recipe::INSTRUCTIONS, Recipe::TASKS.fetch(kind)]
        unless kind == "test"
          instructions << Recipe::OWNER_REVIEW
          instructions.concat(playbooks.map(&:instruction))
        end
        context = { question: question, previous: previous,
          facts: facts.map { |fact| fact.slice("id", "text", "source") } }.compact
        json = JSON.generate(model: MODEL, store: false, service_tier: "default",
          reasoning: { effort: "none" }, max_output_tokens: MAX_OUTPUT, instructions: instructions.join("\n"),
          input: JSON.generate(context), text: { format: {
            type: "json_schema", name: "searchdesk_evidence_selection", strict: true, schema: schema
          } })
        if json.bytesize <= MAX_BYTES
          # UTF-8 bytes bound explicit text tokens. Allow extra framing tokens and conservatively
          # price every input token at the model's highest cache-write rate ($0.25 per million).
          upper_input = json.bytesize + 4096
          maximum_cost = (upper_input + 3) / 4 + (MAX_OUTPUT + 1) / 2
          return Prepared.new(json, facts, maximum_cost, playbooks.map(&:key))
        end
        raise Error.new("input_too_large", charge_uncertain: false) if facts.empty?
        facts.pop
      end
    end

    def call(api_key:, payload:)
      request = Net::HTTP::Post.new(ENDPOINT)
      request["Authorization"] = "Bearer #{api_key}"
      request["Content-Type"] = "application/json"
      request.body = payload.json
      http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port, nil)
      http.use_ssl = true
      http.max_retries = 0
      http.open_timeout, http.write_timeout, http.read_timeout = 4, 5, 20
      Timeout.timeout(30) do
        http.request(request) do |response|
          body = +""
          response.read_body do |part|
            raise Error.new("invalid_response") if body.bytesize + part.bytesize > MAX_RESPONSE_BYTES
            body << part
          end
          return parse_response(response.code.to_i, body, response["x-request-id"])
        end
      end
    rescue Timeout::Error, SocketError, SystemCallError, EOFError, IOError, OpenSSL::SSL::SSLError, Net::ProtocolError
      raise Error.new("unavailable")
    end

    def parse_response(status, body, request_id)
      request_id = nil unless request_id.to_s.match?(/\A[a-zA-Z0-9_-]{1,120}\z/)
      data = JSON.parse(body) rescue nil
      unless status == 200
        provider_code = data.dig("error", "code") if data.is_a?(Hash) && data["error"].is_a?(Hash)
        code = case status
        when 401, 403 then "reconnect"
        when 402 then "credits_exhausted"
        when 429 then QUOTA_CODES.include?(provider_code) ? "credits_exhausted" : "rate_limited"
        when 404 then "model_unavailable"
        else "unavailable"
        end
        raise Error.new(code, charge_uncertain: status >= 500 || status == 408, request_id: request_id)
      end
      raise Error.new("invalid_response", request_id: request_id) unless data.is_a?(Hash)

      texts = Array(data["output"]).select { |item| item.is_a?(Hash) && item["type"] == "message" && item["role"] == "assistant" }
        .flat_map { |item| Array(item["content"]) }
      if data["status"] == "completed" && texts.one? && texts.first.is_a?(Hash) && texts.first["type"] == "output_text"
        selection = JSON.parse(texts.first["text"].to_s) rescue nil
      end
      input, output, cost = usage_cost(data["usage"])
      Response.new(selection, input, output, cost, request_id)
    end

    private

    def usage_cost(usage)
      return unless usage.is_a?(Hash)
      input, output = usage.values_at("input_tokens", "output_tokens")
      return unless [input, output].all? { |v| v.is_a?(Integer) && v.between?(0, 1_000_000) }
      details = usage.fetch("input_tokens_details", {}) || {}
      return unless details.is_a?(Hash)
      cached = details.fetch("cached_tokens", 0)
      writes = details.fetch("cache_write_tokens", 0)
      write_detail = details.fetch("cache_write_tokens_details", {}) || {}
      return unless write_detail.is_a?(Hash)
      short_writes = write_detail.fetch("ttl_30m_tokens", 0)
      return unless [cached, writes, short_writes].all? { |v| v.is_a?(Integer) && v >= 0 }
      return unless short_writes <= writes && cached + writes <= input

      milli_micro = (input - cached - writes) * 100 + cached * 10 + short_writes * 125 + (writes - short_writes) * 250 + output * 500
      [input, output, (milli_micro + 999) / 1000]
    end
  end
end
