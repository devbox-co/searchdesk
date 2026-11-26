require "uri"
require "ipaddr"

module SiteAudits
  class PublicUrl
    NON_PUBLIC_V4 = %w[0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
      172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16
      198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4].map { |range| IPAddr.new(range) }.freeze
    GLOBAL_V6 = IPAddr.new("2000::/3")
    NON_PUBLIC_V6 = %w[2001::/23 2001:db8::/32 2002::/16 3fff::/20].map { |range| IPAddr.new(range) }.freeze
    PRIVATE_PATH = %r{(?:\A|/)(?:\.[^/]+|wp-(?:admin|login\.php|json|cron\.php)|xmlrpc\.php|admin|login|logout|sign[-_]?(?:in|out|up)|account|my-account|checkout|cart|basket|api|feed|private|session|password-reset)(?:/|\z)}i
    NON_PAGE = /\.(?:jpe?g|avif|webp|png|gif|svg|ico|pdf|mp[34]|mov|webm|woff2?|ttf|css|js|json|xml|txt|zip|gz|docx?|xlsx?|csv)\z/i

    def self.public_ip?(value)
      address = IPAddr.new(value)
      return NON_PUBLIC_V4.none? { |range| range.include?(address) } if address.ipv4?
      GLOBAL_V6.include?(address) && NON_PUBLIC_V6.none? { |range| range.include?(address) }
    rescue IPAddr::InvalidAddressError
      false
    end

    def initialize(host)
      @host = host.to_s.downcase
    end

    def resolve(reference, base:, robots: false)
      raw = reference.to_s.strip
      return if raw.blank? || raw.start_with?("#") || raw.bytesize > 2048 || raw.match?(/[\\\x00-\x1f]/)
      uri = URI.join(base.to_s, raw)
      return unless uri.is_a?(URI::HTTP) && uri.port == uri.default_port && !uri.userinfo && !uri.query
      return unless Site::HOST_FORMAT.match?(uri.host.to_s.downcase) && Tracking::ResultUrl.host_matches?(@host, uri.host)
      uri.host = uri.host.downcase
      uri.fragment = nil
      uri.path = "/" if uri.path.blank?
      # Servers can decode encoded separators and dot segments differently from URI and robots rules.
      return if uri.path.match?(%r{%(?:2f|5c)|//}i)
      path = URI::DEFAULT_PARSER.unescape(uri.path)
      return if path.split("/").intersect?([".", ".."])
      return if path.match?(/[\\%?#;\x00-\x1f]/) || path.match?(PRIVATE_PATH) || (!robots && path.match?(NON_PAGE))
      uri
    rescue URI::Error, ArgumentError
      nil
    end
  end
end
