require "net/http"
require "digest"
require "base64"
require "uri"

module GoogleReadOnly
  class Client
    class Error < StandardError; end
    class AccessError < Error; end
    AUTH = "https://accounts.google.com/o/oauth2/v2/auth"
    TOKEN = "https://oauth2.googleapis.com/token"

    def self.configured?
      ENV["GOOGLE_CLIENT_ID"].present? && ENV["GOOGLE_CLIENT_SECRET"].present?
    end

    def self.callback_url
      host = ENV.fetch("APP_HOST") { ENV.fetch("RENDER_EXTERNAL_HOSTNAME", "localhost:3038") }
      protocol = ENV.fetch("APP_PROTOCOL", host.start_with?("localhost", "127.0.0.1") ? "http" : "https")
      raise Error, "Configure a secure application origin" unless protocol == "https" || (protocol == "http" && host.match?(/\A(?:localhost|127\.0\.0\.1)(?::\d+)?\z/))
      raise Error, "Configure a valid application host" unless host.match?(/\A[A-Za-z0-9.-]+(?::\d+)?\z/)
      Rails.application.routes.url_helpers.public_send(self::CALLBACK_ROUTE, host: host, protocol: protocol)
    end

    def self.authorization_url(state:, verifier:)
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      "#{AUTH}?#{URI.encode_www_form(client_id: ENV.fetch("GOOGLE_CLIENT_ID"), redirect_uri: callback_url,
        scope: self::SCOPE, response_type: "code", access_type: "offline", prompt: "consent", state: state,
        code_challenge: challenge, code_challenge_method: "S256")}"
    end

    def exchange(code:, verifier:)
      validate_token(json_request(TOKEN, form: auth_fields.merge(code: code, code_verifier: verifier,
        redirect_uri: self.class.callback_url, grant_type: "authorization_code")))
    end

    def refresh(token)
      validate_token(json_request(TOKEN, form: auth_fields.merge(refresh_token: token, grant_type: "refresh_token")))
    end

    private

    def validate_token(data)
      expiry = Integer(data["expires_in"].to_s, 10, exception: false)
      unless data["access_token"].is_a?(String) && data["access_token"].present? && expiry&.positive? &&
             (!data.key?("scope") || data["scope"].is_a?(String))
        raise Error, "Google returned an incomplete token response."
      end
      data
    end

    def auth_fields
      { client_id: ENV.fetch("GOOGLE_CLIENT_ID"), client_secret: ENV.fetch("GOOGLE_CLIENT_SECRET") }
    end

    def json_request(url, token: nil, json: nil, form: nil)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 4
      http.read_timeout = 12
      http.write_timeout = 10
      http.max_retries = 0
      req = (json || form ? Net::HTTP::Post : Net::HTTP::Get).new(uri.request_uri)
      req["Authorization"] = "Bearer #{token}" if token
      req.set_form_data(form) if form
      if json
        req.content_type = "application/json"
        req.body = JSON.generate(json)
      end
      raw = +""
      status = http.start do |session|
        session.request(req) do |reply|
          reply.read_body do |part|
            raise Error, "Google returned more data than the report limit." if raw.bytesize + part.bytesize > 4.megabytes
            raw << part
          end
        end
      end.code
      body = raw.present? ? JSON.parse(raw) : {}
      raise Error, "Google returned an invalid response" unless body.is_a?(Hash)
      unless status.start_with?("2")
        auth_error = status == "401" || body["error"] == "invalid_grant"
        denied = status == "403" && body["error"].is_a?(Hash) && Array(body.dig("error", "errors")).grep(Hash).any? { |e| %w[insufficientPermissions forbidden].include?(e["reason"]) }
        raise AccessError, "Google access was removed. Reconnect the selected property." if auth_error || denied
        raise Error, "Google request could not complete (HTTP #{status})."
      end
      body
    rescue IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, JSON::ParserError
      raise Error, "Google did not return a usable response. Try again later."
    end
  end
end
