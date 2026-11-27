require "test_helper"

class OrganicPageOverlapTest < ActiveSupport::TestCase
  test "retains all observed own pages and corroborates only a pair in one verified local sample" do
    site = Workspace.create!(name: "Local example").sites.create!(name: "Heating", host: "heating.example", location: "York",
      time_zone: "Europe/London", tracking_mode: "dataforseo", rank_location_code: 100,
      rank_location_name: "York", rank_location_verified_at: Time.current)
    pages = %w[advice service prices other].map { |path| "https://heating.example/#{path}" }
    keyword = Tracking::Enrollment.call(site: site, phrase: "heating york", preferred_url: pages[1], devices: ["desktop"])
    items = [*pages.first(3), "https://elsewhere.example/", pages.last].each_with_index.map do |url, i|
      { "type" => "organic", "rank_group" => [1, 2, 3, 4, 8].fetch(i), "url" => url }
    end
    r = Tracking::RecordResult.call(series: keyword.tracking_series.sole, captured_at: Time.current, items: items.reverse)
    assert_equal pages, r.evidence.fetch("site_organic_pages").pluck("url")
    lookup = ->(urls, device = "desktop") { Tracking::OrganicPageOverlap.for(keyword:, device:, urls:) }
    assert_equal [2, 3], lookup.call(pages[1, 2]).fetch(:pages).pluck(:position)
    assert_nil lookup.call(pages.last(2))
    assert_nil lookup.call(pages.first(2), "mobile")
    r.update!(evidence: r.evidence.except("site_organic_pages"))
    assert_equal [1, 2], lookup.call(pages.first(2)).fetch(:pages).pluck(:position)
    assert_nil lookup.call(pages[1, 2])
  end
end
