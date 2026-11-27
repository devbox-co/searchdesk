require "net/http"

module SeoWorkflows
  class SlackWebhook
    class Error < StandardError; end

    URL_PATTERN = %r{\Ahttps://hooks\.slack\.com/services/[A-Za-z0-9]{5,32}/[A-Za-z0-9]{5,32}/[A-Za-z0-9_-]{10,100}\z}

    def self.valid?(value) = value.is_a?(String) && URL_PATTERN.match?(value)

    def deliver!(webhook:, label:, path:)
      raise Error, "Invalid Slack destination" unless self.class.valid?(webhook)

      uri = URI(webhook)
      request = Net::HTTP::Post.new(uri.request_uri)
      request.content_type = "application/json"
      request.body = JSON.generate(text: "Searchdesk · #{label}\n#{path}", unfurl_links: false, unfurl_media: false)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 4
      http.read_timeout = 8
      http.write_timeout = 8
      http.max_retries = 0
      http.start do |session|
        session.request(request) do |reply|
          result = +""
          reply.read_body do |part|
            raise Error, "Slack could not confirm delivery" if result.bytesize + part.bytesize > 1024
            result << part
          end
          raise Error, "Slack could not confirm delivery" unless reply.code == "200" && result.strip == "ok"
        end
      end
    end
  end
end
