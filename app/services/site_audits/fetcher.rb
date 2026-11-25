require "net/http"
require "openssl"
require "socket"
require "timeout"

module SiteAudits
  class Fetcher
    AGENT = "SearchdeskBot/1.0"
    MAX_BYTES = 2 * 1024 * 1024
    Response = Data.define(:status, :location, :content_type, :robots_header, :body)
    class Error < StandardError; end

    def initialize(resolver: Addrinfo, transport: Net::HTTP)
      @resolver, @transport = resolver, transport
    end

    def get(uri, robots: false)
      Timeout.timeout(12) do
        addresses = @resolver.getaddrinfo(uri.hostname, nil, nil, :STREAM).map(&:ip_address).uniq
        unless addresses.any? && addresses.all? { |address| PublicUrl.public_ip?(address) }
          raise Error, "The hostname did not resolve exclusively to public addresses."
        end
        # Pin the checked address while retaining the URL hostname for TLS verification, SNI and Host.
        http = @transport.new(uri.hostname, uri.port, nil)
        http.ipaddr = addresses.find { |address| IPAddr.new(address).ipv4? } || addresses.first
        http.use_ssl = uri.scheme == "https"
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
        http.open_timeout = 4
        http.read_timeout = 6
        http.max_retries = 0
        request = Net::HTTP::Get.new(uri.request_uri, "User-Agent" => AGENT, "Accept-Encoding" => "identity",
          "Accept" => robots ? "text/plain,*/*;q=0.1" : "text/html,application/xhtml+xml")
        http.request(request) do |response|
          status = response.code.to_i
          type = response["content-type"].to_s.split(";").first.to_s.strip.downcase
          body = +"".b
          if status.between?(200, 299) && (robots || %w[text/html application/xhtml+xml].include?(type))
            raise Error, "The server returned an unsupported encoding." unless ["", "identity"].include?(response["content-encoding"].to_s.downcase)
            response.read_body do |chunk|
              raise Error, "The response exceeded the audit size limit." if body.bytesize + chunk.bytesize > (robots ? 512.kilobytes : MAX_BYTES)
              body << chunk
            end
          end
          # Leave the session from inside its response block. Net::HTTP otherwise drains an ignored body.
          return Response.new(status, response["location"], type, response.get_fields("x-robots-tag").to_a.join(", ").first(4096), body)
        end
      end
    rescue Timeout::Error, IOError, EOFError, SocketError, SystemCallError, OpenSSL::SSL::SSLError, Net::ProtocolError
      raise Error, "The server could not be reached with a verified connection."
    end
  end
end
