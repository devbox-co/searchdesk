class DemoSiteSetup
  DEFAULTS = {
    name: "Northline Heating", host: "northline.example", location: "Basingstoke"
  }.freeze

  # A nil rank represents a completed search with the business outside the top 30.
  EXAMPLES = {
    "boiler servicing" => { path: "/boiler-servicing/", first_week: [14, 13, 11, 12, 10, 9, 8] },
    "boiler repair" => { path: "/boiler-repairs/", first_week: [6, 7, 6, 8, 11, 10, 12] },
    "heating engineer" => { path: "/", first_week: [9, 8, 9, 10, 11, 10, 9] },
    "radiator repair" => { path: "/radiators/", first_week: [nil, nil, 29, 30, 28, 26, 25] },
    "heat pump installation" => { path: "/heat-pumps/", first_week: [17, 18, 17, 16, 15, 16, 14], homepage_from_day: 4 }
  }.freeze

  def self.call(site)
    raise ArgumentError, "Only demo sites can receive sample rankings" unless site.tracking_mode == "demo"
    EXAMPLES.each do |service, example|
      Tracking::Enrollment.call(site: site, phrase: "#{service} #{site.location.downcase}",
        preferred_url: "https://#{site.host}#{example.fetch(:path)}")
    end
  end
end
