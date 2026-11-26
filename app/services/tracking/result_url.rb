require "uri"

module Tracking
  module ResultUrl
    def self.parse(value)
      url = URI.parse(value.to_s)
      url if url.is_a?(URI::HTTP) && url.host.present? && url.userinfo.nil?
    rescue URI::InvalidURIError
      nil
    end

    def self.host_matches?(configured_host, found_host)
      configured_host.to_s.downcase.delete_prefix("www.") == found_host.to_s.downcase.delete_prefix("www.")
    end

    def self.same_page?(expected, actual)
      a = parse(expected)
      b = parse(actual)
      return false unless a && b && host_matches?(a.host, b.host)
      [a.scheme, a.port, a.path.presence || "/", a.query] == [b.scheme, b.port, b.path.presence || "/", b.query]
    end
  end
end
