class IntegrationCatalogue
  Entry = Struct.new(:key, :name, :group, :mode, :description, keyword_init: true)

  ROWS = [
    ["openai", "OpenAI assistant", "Site analysis", "Owner’s API project", "Answer questions and prepare daily briefs using the site evidence the owner chooses to share."],
    ["google-search-console", "Google Search Console", "Search performance", "Read-only OAuth", "See Google Web clicks, impressions and average position. Tracked query averages combine devices within your selected country."],
    ["google-analytics", "Google Analytics 4", "Website traffic", "Read-only OAuth", "Compare Google organic sessions, engaged sessions and key events on the verified website. Check event definitions before counting enquiries."],
    ["dataforseo", "DataForSEO", "Organic rankings", "Platform-managed API", "Sample the first 30 Google organic results by town, keyword and device. Each new sample uses the managed provider account."],
    ["local-falcon", "Local Falcon", "Maps coverage", "Read existing reports", "Read completed Google Maps grids, existing campaign schedules and linked Business Profile activity. New scans follow your Local Falcon campaign schedule."],
    ["website", "Public website", "Website", "Website link", "Visit the site's public homepage. The link opens the selected business's website."],
    ["rank-import", "File import", "Saved evidence", "Manual JSON import", "Import scoped organic result observations for a manually tracked keyword and device."],
    ["google-business-profile", "Google Business Profile", "Business listings", "Provider portal or linked reporting", "View listing activity through an authorised Local Falcon account, or open the native Business Profile manager."],
    ["wordpress", "WordPress", "Website", "Planned", "Future adapter for individual approved site edits and public verification."],
    ["semrush", "Semrush", "Campaign rankings", "Imported reports", "Import an existing Position Tracking campaign as Searchdesk evidence JSON. Its campaign, location, device and search features keep their own ranking history."],
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

  SEARCH_TERMS = {
    "openai" => %w[AI assistant ChatGPT daily brief],
    "google-search-console" => %w[GSC clicks impressions average\ position search\ performance],
    "google-analytics" => %w[GA4 website\ visits sessions engaged\ sessions events enquiries],
    "dataforseo" => %w[local\ organic\ rankings keyword\ rankings desktop mobile town],
    "local-falcon" => %w[Maps grid geogrid map\ pack GBP Business\ Profile],
    "google-business-profile" => %w[GBP Google\ Maps listing calls directions website\ clicks],
    "rank-import" => %w[local\ organic\ rankings manual\ observation],
    "semrush" => %w[keyword\ rankings Position\ Tracking search\ features local\ pack]
  }.freeze

  def self.find!(key)
    ROWS.find { |row| row.key == key } || raise(ActiveRecord::RecordNotFound)
  end

  def self.search(query)
    clean = ->(string) { string.to_s.downcase.gsub(/[^a-z0-9]/, "") }
    term = clean.call(query)
    ROWS.select do |entry|
      [entry.name, entry.key, entry.group, *SEARCH_TERMS[entry.key]].any? { |value| clean.call(value).include?(term) }
    end
  end
end
