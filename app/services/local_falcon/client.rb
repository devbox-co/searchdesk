require "net/http"
require "uri"
require "base64"
require "digest"

module LocalFalcon
  class Client
    class Error < StandardError; end
    class AccessError < Error; end
    class ToolError < Error; end
    ORIGIN = "https://mcp.localfalcon.com"
    VERSION = "2025-06-18"
    READ_TOOLS = %w[listAllLocalFalconLocations listLocalFalconScanReports getLocalFalconReport listLocalFalconCampaignReports getLocalFalconGbpPerformanceMetrics].freeze

    def self.callback_url
      host = ENV.fetch("APP_HOST") { ENV.fetch("RENDER_EXTERNAL_HOSTNAME", "localhost:3038") }
      protocol = ENV.fetch("APP_PROTOCOL", host.match?(/\A(?:localhost|127\.0\.0\.1)(?::\d+)?\z/) ? "http" : "https")
      unless host.match?(/\A[a-zA-Z0-9.-]+(?::\d+)?\z/) && (protocol == "https" || (protocol == "http" && host.match?(/\A(?:localhost|127\.0\.0\.1)(?::\d+)?\z/)))
        raise Error, "Set the application’s public origin or loopback address first."
      end
      Rails.application.routes.url_helpers.callback_local_falcon_connection_url(host: host, protocol: protocol)
    end

    def register(callback)
      obj, = request("/register", json: { client_name: "Searchdesk private reporting", redirect_uris: [callback],
        grant_types: %w[authorization_code refresh_token], response_types: ["code"], token_endpoint_auth_method: "none" })
      id = obj["client_id"]
      raise Error, "Local Falcon did not register this application." unless id.is_a?(String) && id.present? && id.size <= 255
      id
    end

    def authorize_url(id, callback, state, verifier)
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      "#{ORIGIN}/oauth/authorize?#{URI.encode_www_form(client_id: id, redirect_uri: callback, response_type: 'code',
        scope: 'api offline_access', resource: ORIGIN, code_challenge: challenge, code_challenge_method: 'S256', state: state)}"
    end

    def token(id, fields)
      obj, = request("/oauth/token", form: fields.merge(client_id: id, resource: ORIGIN))
      expiry = Integer(obj["expires_in"], exception: false)
      unless obj["access_token"].is_a?(String) && obj["access_token"].present? && expiry&.positive? && obj.fetch("token_type","bearer").to_s.casecmp?("bearer")
        raise Error, "Local Falcon returned an incomplete access grant."
      end
      obj
    end

    def revoke(id, refresh)
      request("/oauth/revoke", form: { client_id: id, token: refresh, token_type_hint: "refresh_token" }) if refresh.present?
    end

    def open_session(token)
      @token = token
      @sequence = 0
      body, headers = call_rpc("initialize", { protocolVersion: VERSION, capabilities: {}, clientInfo: { name: "searchdesk", version: "1" } })
      protocol = body["protocolVersion"]
      raise Error, "Local Falcon returned an unsupported protocol." unless %w[2024-11-05 2025-03-26 2025-06-18 2025-11-25].include?(protocol)
      @protocol = protocol
      @session = headers["mcp-session-id"]
      call_rpc("notifications/initialized", nil, notification: true)
      self
    end

    def read(tool, args)
      raise Error, "Unsupported Local Falcon operation." unless READ_TOOLS.include?(tool)
      result, = call_rpc("tools/call", { name: tool, arguments: args })
      raise ToolError, "Local Falcon could not read the requested record." if result["isError"]
      # Hosted tools may return structuredContent or a JSON text content block.
      data = result["structuredContent"]
      data = JSON.parse(result.fetch("content").detect { |v| v["type"] == "text" }.fetch("text")) unless data.is_a?(Hash)
      raise ToolError, "Local Falcon could not read the requested record." if data["success"] == false
      data = data.fetch("data") if data.key?("success")
      raise Error, "Local Falcon returned invalid report data." unless data.is_a?(Hash)
      data
    rescue JSON::ParserError, KeyError, NoMethodError, TypeError
      raise Error, "Local Falcon returned invalid report data."
    end

    private

    def call_rpc(method, params, notification: false)
      rpc = { jsonrpc: "2.0", method: method }
      rpc[:id] = (@sequence += 1) unless notification
      rpc[:params] = params if params
      obj, headers = request("/mcp", json: rpc, rpc_id: rpc[:id])
      return [{}, headers] if notification
      unless obj["id"] == rpc[:id] && obj["result"].is_a?(Hash)
        raise Error, "Local Falcon could not complete the read request."
      end
      [obj["result"], headers]
    end

    def request(path, json: nil, form: nil, rpc_id: nil)
      uri = URI(ORIGIN + path)
      req = Net::HTTP::Post.new(uri)
      if path == "/mcp"
        req["Authorization"] = "Bearer #{@token}"
        req["Accept"] = "application/json, text/event-stream"
        req["MCP-Protocol-Version"] = @protocol if @protocol
        req["Mcp-Session-Id"] = @session if @session
      end
      if form
        req.set_form_data(form)
      else
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(json)
      end
      raw = +""
      received = 0
      reply = Net::HTTP.start(uri.host, 443, use_ssl: true, open_timeout: 5, read_timeout: 15, write_timeout: 8) do |http|
        http.request(req) do |r|
          events = r.is_a?(Net::HTTPSuccess) && r["content-type"].to_s.start_with?("text/event-stream")
          r.read_body do |chunk|
            received += chunk.bytesize
            raise Error, "Local Falcon returned more data than requested." if received > 2.megabytes
            raw << chunk
            if events
              while (boundary = raw.match(/\r?\n\r?\n/))
                lines = raw.slice!(0, boundary.end(0)).lines.filter_map { |line| line.delete_prefix("data:").strip if line.start_with?("data:") }
                next if lines.empty?
                packet = JSON.parse(lines.join("\n"))
                # The stream may stay open after our response. A one-shot client can close now.
                return [packet, r] if rpc_id && packet.is_a?(Hash) && packet["id"] == rpc_id
              end
            end
          end
        end
      end
      raise AccessError, "Local Falcon access expired. Reconnect this account." if reply.code == "401" || (path == "/oauth/token" && reply.code == "400" && raw.include?("invalid_grant"))
      raise Error, "Local Falcon could not complete the request (HTTP #{reply.code})." unless reply.is_a?(Net::HTTPSuccess)
      obj = raw.blank? ? {} : JSON.parse(raw)
      raise Error, "Local Falcon returned an invalid response." unless obj.is_a?(Hash)
      [obj, reply]
    rescue IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, JSON::ParserError
      raise Error, "Local Falcon did not return a usable response. Try again later."
    end
  end
end
