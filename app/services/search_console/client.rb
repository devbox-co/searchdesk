module SearchConsole
  class Client < GoogleReadOnly::Client
    SCOPE = "https://www.googleapis.com/auth/webmasters.readonly"
    GOOGLE = "https://www.googleapis.com/webmasters/v3"
    CALLBACK_ROUTE = :callback_search_console_url

    def properties(token:, host:)
      entries = json_request("#{GOOGLE}/sites", token: token).fetch("siteEntry", [])
      raise Error, "Google returned an invalid property list" unless entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(Hash) }
      entries.filter_map do |entry|
        id = entry["siteUrl"]
        id if %w[siteOwner siteFullUser siteRestrictedUser].include?(entry["permissionLevel"]) && self.class.matches?(id, host)
      end.uniq
    end

    def self.matches?(id, host)
      return false unless id.is_a?(String)
      if id.start_with?("sc-domain:")
        return Tracking::ResultUrl.host_matches?(host, id.delete_prefix("sc-domain:"))
      end
      url = Tracking::ResultUrl.parse(id)
      url && url.path == "/" && url.port == url.default_port && !url.fragment && !url.query && Tracking::ResultUrl.host_matches?(host, url.host)
    end

    def sitemaps(token:, property:)
      encoded = ERB::Util.url_encode(property)
      json_request("#{GOOGLE}/sites/#{encoded}/sitemaps", token: token).fetch("sitemap", [])
    end

    def query(token:, property:, payload:)
      encoded = ERB::Util.url_encode(property)
      json_request("#{GOOGLE}/sites/#{encoded}/searchAnalytics/query", token: token, json: payload).fetch("rows", [])
    end
  end
end
