class IntegrationCatalogue
  Entry = Struct.new(:key, :name, :group, :mode, :description, keyword_init: true)

  ROWS = [
    ["google-search-console", "Google Search Console", "Search performance", "Read-only OAuth", "Connect a confirmed property to read search activity with your permission."],
    ["google-analytics", "Google Analytics 4", "Business outcomes", "Read-only OAuth", "Connect a GA4 property to compare Google organic sessions and unverified key events for this website."],
    ["dataforseo", "DataForSEO", "Organic rankings", "Platform-managed API", "Collect daily organic observations for the site's configured location and devices."],
    ["local-falcon", "Local Falcon", "Maps coverage", "Read existing reports", "Connect a private Local Falcon account to refresh existing Maps reports, campaign schedules and linked Business Profile metrics."],
    ["website", "Public website", "Website", "Website link", "Visit the site's public homepage. The link opens the selected business's website."],
    ["rank-import", "File import", "Saved evidence", "Manual JSON import", "Import scoped organic result observations for a manually tracked keyword and device."],
    ["google-business-profile", "Google Business Profile", "Business listings", "Provider portal or linked reporting", "View listing activity through an authorised Local Falcon account, or open the native Business Profile manager."],
    ["wordpress", "WordPress", "Website", "Planned", "Future adapter for individual approved site edits and public verification."],
    ["semrush", "Semrush", "Keyword research", "Imported reports", "Browse Semrush evidence imported for this site. Automatic Semrush API sync is unavailable."],
    ["ahrefs", "Ahrefs", "Links", "Planned", "Potential source for licensed referring-page and backlink evidence."],
    ["screaming-frog", "Screaming Frog", "Website", "Planned", "Potential import of scoped crawl exports."],
    ["brightlocal", "BrightLocal", "Local listings", "Planned", "Potential source for listing and citation evidence."],
    ["whitespark", "Whitespark", "Local listings", "Planned", "Potential source for citation evidence."],
    ["local-seo-data", "Local SEO Data", "Local visibility", "Planned", "Potential source for separate Maps grid observations."],
    ["serpapi", "SerpAPI", "Organic rankings", "Planned", "Alternative observation provider with an independent baseline."],
    ["lsa-spy", "LSA Spy", "Paid local search", "Planned", "Potential source for Local Services Ads evidence."]
  ].map do |key, name, group, mode, description|
    Entry.new(key: key, name: name, group: group, mode: mode, description: description).freeze
  end.freeze

  PORTALS = {
    "google-search-console" => "https://search.google.com/search-console",
    "google-analytics" => "https://analytics.google.com/",
    "google-business-profile" => "https://business.google.com/"
  }.freeze

  def self.find!(key)
    ROWS.find { |row| row.key == key } || raise(ActiveRecord::RecordNotFound)
  end

  def self.search(query)
    clean = ->(string) { string.to_s.downcase.gsub(/[^a-z0-9]/, "") }
    term = clean.call(query)
    ROWS.select { |entry| [entry.name, entry.key, entry.group].any? { |value| clean.call(value).include?(term) } }
  end
end
