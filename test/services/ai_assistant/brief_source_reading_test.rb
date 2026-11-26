require "test_helper"

class BriefSourceReadingTest < ActiveSupport::TestCase
  def reading(source, text)
    AiAssistant::BriefSourceReading.for({ "source" => source, "text" => text })
  end

  test "weekly change names a measured search and keeps its comparison coverage" do
    summary = reading("Weekly search clicks", "UK Google web search, all devices. Comparing 2026-11-01 to 2026-11-07 with 2026-11-08 to 2026-11-14, 2 of 8 tracked searches had reported click counts on all 14 days. “boiler repairs” fell from 3 to 0 clicks. “heating engineers” rose from 3 to 7 clicks.")
    assert_equal "Clicks rose for “heating engineers”", summary[:headline]
    assert_includes summary[:meaning], "3 to 7"
    assert_includes summary[:meaning], "2 of 8 tracked searches"
    assert_no_match(/2026|14 days/, summary[:meaning])
    unavailable = reading("Weekly search clicks", "0 of 8 tracked searches had reported click counts on all 14 days.")
    assert_includes unavailable[:headline], "isn’t available"
    assert_nil reading("Weekly search clicks", "Data may change.")
  end

  test "Maps comparisons use matched locations and keep the scan distinct from the town" do
    summary = reading("Local Falcon", "boiler repairs, Google Maps scan for Guildford on 2026-11-24, 7×7 grid. Radius 5.0 mi. Top three on 29 of 49 pins. Compared with 2026-11-23 on 40 matched pins, gained top-three on 4 and lost it on 2.")
    assert_equal "Google Maps visibility for “boiler repairs”", summary[:headline]
    assert_includes summary[:meaning], "29 of 49 locations checked"
    assert_includes summary[:meaning], "2 more among the locations checked both times"
    assert_nil reading("Local Falcon", "boiler repairs, Google Maps scan for Guildford on 2026-11-24, 7×7 grid. Share of local voice 60%.")
  end

  test "GA4 visit totals preserve limits and only describe trends with a comparison" do
    summary = reading("Google Analytics 4", "Google / organic traffic for example.com, 2026-10-25 through 2026-11-21 recorded 15 sessions, 10 engaged sessions. Key events are unvalidated as enquiries. Google flagged sampling, thresholds or aggregation limits.")
    assert_includes summary[:meaning], "15 visits"
    assert_includes summary[:meaning], "Google flagged limits"
    refute_match(/fell|rose|enquiries|example.com|2026/, summary[:meaning])
    comparison = reading("Google Analytics 4", "Google organic sessions were 2 lower in the 28 days through 2026-11-21 (15) compared with the preceding 28 days through 2026-10-24 (17).")
    assert_equal "Visits from Google fell", comparison[:headline]
    no_total = reading("Google Analytics 4", "Google / organic traffic for example.com, 2026-10-25 through 2026-11-21 recorded no matching rows.")
    assert_includes no_total[:meaning], "no visit total"
  end

  test "enquiry validation has an actionable check and does not expose a task-system label" do
    summary = reading("Project tasks", "“Validate enquiry measurement and design a success-based lead event” is a high priority project task. Its current status is needs evidence.")
    assert_equal "Check how enquiries are counted", summary[:headline]
    assert_includes summary[:action], "business records"
    assert summary[:priority].between?(25, 35)
    assert_nil reading("Project tasks", "This is someone's draft.")
  end

  test "Search Console and campaign use different descriptions and handle reported zero" do
    result = reading("Google Search Console", "boiler repair, 2026-11-23, GBR, Google web search, all devices, final API — average position 5.0, 7 impressions and 0 clicks. No comparable reading on 2026-11-25.")
    assert_includes result[:meaning], "7 times"
    assert_includes result[:meaning], "0 clicks"
    total = reading("Google Search Console", "Google web search, all countries and devices, 2026-10-27 through 2026-11-23 recorded 0 clicks and 192 impressions.")
    assert_includes total[:headline], "no search clicks"
    semrush = reading("Semrush Position Tracking", "boiler, 2026-11-23, Guildford, England, United Kingdom, desktop — position 6 in Semrush's feature-inclusive campaign. Numeric baseline 9 on 2026-11-03.")
    assert_includes semrush[:meaning], "from 9 to 6"
    assert_includes semrush[:meaning], "desktop"
  end

  def search_period(start_day, end_day, clicks)
    { "source" => "Google Search Console", "text" => "Google web search, all countries and devices, #{start_day} through #{end_day} recorded #{clicks} clicks and 43 impressions." }
  end

  def traffic_period(host, start_day, end_day, visits)
    { "source" => "Google Analytics 4", "text" => "Google / organic traffic for #{host}, #{start_day} through #{end_day} recorded #{visits} sessions, 0 engaged sessions. Key events are unvalidated as enquiries." }
  end

  test "a pair of adjacent complete periods shows a trend and links to the newer observation" do
    before = search_period("2026-09-29", "2026-10-26", 3)
    after = search_period("2026-10-27", "2026-11-23", 0)
    [ [before, after], [after, before] ].each do |pair|
      summary = AiAssistant::BriefSourceReading.comparison(pair)
      assert_equal "Clicks from Google search fell", summary[:headline]
      assert_equal "There were 0 clicks in four weeks, compared with 3 in the previous four weeks.", summary[:meaning]
      assert_same after, summary[:action_fact]
    end
  end

  test "a visit comparison carries either period's limits and requires a matching host" do
    before = traffic_period("same.example", "2026-09-29", "2026-10-26", 1)
    before["text"] += " Google flagged sampling, thresholds or aggregation limits."
    after = traffic_period("same.example", "2026-10-27", "2026-11-23", 1)
    summary = AiAssistant::BriefSourceReading.comparison([after, before])
    assert_equal "Visits from Google search held steady", summary[:headline]
    assert_includes summary[:meaning], "Google flagged limits"
    assert_same after, summary[:action_fact]
    assert_nil AiAssistant::BriefSourceReading.comparison([before, traffic_period("other.example", "2026-10-27", "2026-11-23", 5)])
  end

  test "missing readings, mixed sources, gaps, overlaps and short periods cannot make a trend" do
    before = search_period("2026-09-29", "2026-10-26", 3)
    after = search_period("2026-10-27", "2026-11-23", 1)
    missing = after.merge("text" => after["text"].sub("1 clicks and 43 impressions", "no matching rows"))
    [
      [after], [before, after, after], [before, missing],
      [before, traffic_period("same.example", "2026-10-27", "2026-11-23", 4)],
      [before, search_period("2026-10-28", "2026-11-24", 1)],
      [before, search_period("2026-10-26", "2026-11-22", 1)],
      [before, search_period("2026-10-27", "2026-11-22", 1)],
      [before, search_period("2026-10-27", "2026-02-31", 1)]
    ].each { |pair| assert_nil AiAssistant::BriefSourceReading.comparison(pair) }
  end

  test "Business Profile interaction counts remain distinct from confirmed enquiries" do
    summary = reading("Google Business Profile via Local Falcon", "Business Profile interactions, 2026-10-25 through 2026-11-21 included 2 website clicks, 1 call clicks, 3 direction requests. Qualified enquiries are unverified.")
    assert_includes summary[:meaning], "3 requests for directions"
    assert_includes summary[:meaning], "Enquiries still need to be confirmed"
    assert_nil reading("Google Analytics 4", "Some other observation")
    assert_nil reading("Other source", "A source changed.")
  end
end
