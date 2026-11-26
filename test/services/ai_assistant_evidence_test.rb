require "test_helper"

class AiAssistantEvidenceTest < ActiveSupport::TestCase
  setup do
    @site = new_site("Heating", "example.test")
    @setting = @site.create_ai_setting!(enabled: true)
    @day = Date.new(2026, 11, 15)
    travel_to @day.noon
  end

  def new_site(name, host)
    Workspace.create!(name: name).sites.create!(name: name, host: host, location: "Example Town", language: "en",
      rank_country_code: "GB", time_zone: "Europe/London", tracking_mode: "manual")
  end

  def evidence(question, site: @site, setting: @setting, day: @day, **opts)
    AiAssistant::Evidence.build(site:, setting:, question:, day:, kind: "question", **opts)
  end

  def visible?(bundle, site: @site, setting: @setting)
    AiAssistant::Evidence.visible?(site:, setting:, evidence: JSON.parse(bundle.to_json))
  end

  def observe(phrase, device, win, depth: 30, winner: "/preferred", day: @day)
    keyword = Tracking::Enrollment.call(site: @site, phrase:, preferred_url: "https://example.test/preferred", devices: [device])
    series = keyword.tracking_series.current.find_by!(device:)
    items = (1..depth).map do |n|
      url = n == win ? "https://example.test#{winner}" : "https://result-#{n}.invalid/"
      {"type" => "organic", "rank_group" => n, "url" => url}
    end
    Tracking::ManualImport.call(series:, payload: {"source" => "manual", "keyword" => phrase, "host" => @site.host,
      "language" => @site.language, "location" => @site.location, "device" => device, "depth" => 30,
      "captured_at" => "#{day}T08:00:00Z", "items" => items})
  end

  def texts(bundle)
    bundle.fetch("facts").pluck("text").join(" ")
  end

  test "a full daily brief retains late sources and records only the selected evidence references" do
    @setting.update!(share_semrush: true)
    builder = AiAssistant::Evidence.new(@site, @setting, nil, @day, "brief", nil)
    limit = AiAssistant::Evidence::MAX_FACTS
    builder.define_singleton_method(:read_rankings) do
      (1..limit).each { |id| fact("Manual rank #{id}", "Manual import", "/rankings", observations: [id]) }
    end
    builder.define_singleton_method(:read_campaign) do
      fact("Imported campaign position", "Semrush Position Tracking", "/source_snapshots/1", sources: ["semrush"], snapshots: [1])
    end

    bundle = builder.build
    assert_equal limit, bundle.fetch("facts").size
    assert_equal "Manual import", bundle.fetch("facts").first.fetch("source")
    assert_equal "Semrush Position Tracking", bundle.fetch("facts").last.fetch("source")
    assert_includes bundle.dig("access", "sources"), "semrush"
    assert_equal [1], bundle.dig("access", "records", "snapshots")
    refute_includes bundle.dig("access", "records", "observations"), limit
  end

  test "first collection separates baselines, incomplete checks, distinct affected keywords and safe page paths" do
    %w[desktop mobile].each { |device| observe("boiler service", device, 8, winner: "/other?q=private#token") }
    %w[desktop mobile].each { |device| observe("heater fitting", device, 12) }
    observe("valve change", "mobile", nil)
    observe("valve change", "desktop", nil, depth: 27)
    bundle = evidence("What should I check first?")
    summary = texts(bundle)
    assert_includes summary, "6 keyword-device checks across 3 keywords"
    assert_includes summary, "4 numeric positions, 1 verified outside the top 30, 1 incomplete"
    assert_includes summary, "5 usable baselines"
    assert_includes summary, "Movement needs observations on two comparable dates"
    assert_includes summary, "2 currently open device readings for 1 distinct keyword"
    assert_includes summary, "Winning page /other."
    assert_no_match(/private|#token/, summary)
    assert visible?(bundle)
    assert_equal bundle.fetch("facts").size, bundle.fetch("facts").pluck("id").uniq.size
    bundle.fetch("facts").each do |f|
      path = URI.parse(f.fetch("url"))
      assert_nil path.host
      assert Rails.application.routes.recognize_path(path.path, method: :get)
    end
    targeted = texts(evidence("Where did valve change rank on desktop?"))
    assert_includes targeted, "incomplete coverage through 27"
    assert_no_match(/boiler service|heater fitting/, targeted)
  end

  test "missing day stays missing and a later comparable reading uses its original device baseline" do
    observe("heating", "mobile", 12)
    travel_to((@day + 2).noon)
    observe("heating", "mobile", 5, day: @day + 2)
    assert_includes texts(evidence("How is heating ranking?", day: @day + 2)), "Up 7 places since baseline"
    missing = texts(evidence("How did heating rank yesterday?", day: @day + 2))
    assert_includes missing, "missing, with no reading"
    assert_includes missing, "Latest comparable reading was #{@day}"
    assert_no_match(/position 5|7 places/, missing)
  end

  test "source consent, cross-site isolation, and deletion are evaluated again when reading history" do
    observe("pump repair", "mobile", 8)
    bundle = evidence("Where does pump repair rank?")
    other = new_site("Other", "another.test")
    other_setting = other.create_ai_setting!(enabled: true)
    assert_not visible?(bundle, site: other, setting: other_setting)
    assert_raises(ArgumentError) { evidence("Who ranks?", site: other) }
    assert_empty texts(evidence("pump repair", site: other, setting: other_setting)).scan(/pump repair/)
    @site.keywords.destroy_all
    assert_not visible?(bundle)
  end

  test "a follow-up only picks keywords from a still-visible answer on the same site" do
    observe("pump repair", "mobile", 8)
    observe("valve service", "mobile", 7)
    prior = Struct.new(:site_id, :question, :evidence, :erased_at).new(@site.id, "how did pump repair rank?", evidence("pump repair"))
    follow_up = texts(evidence("What about it on mobile?", parent: prior))
    assert_includes follow_up, "pump repair"
    assert_no_match(/valve service/, follow_up)
    prior.site_id = new_site("Elsewhere", "elsewhere.test").id
    assert_includes texts(evidence("What about it on mobile?", parent: prior)), "valve service"
  end

  test "analytics uses verified neighboring periods and excludes URL filters, account identifiers, unrelated streams and unvalidated leads" do
    connection = @site.create_analytics_connection!(grant_key: SecureRandom.uuid, status: "connected", property_id: "945623878",
      verified_host: @site.host, stream_ids: ["approved"])
    add_period = lambda do |through, sessions, streams|
      id = "ga4-google-organic-v1-#{connection.property_id}-#{Digest::SHA256.hexdigest(@site.host).first(24)}-#{through}"
      @site.source_snapshots.create!(provider: "Google Analytics 4", external_id: id, title: "Private raw title",
        scope: "utm_secret", observed_on: through, metrics: {"start" => (through - 27).iso8601, "end" => through.iso8601,
          "stream_ids" => streams, "property_id" => connection.property_id,
          "metrics" => {"sessions" => sessions, "engaged_sessions" => sessions - 5, "unverified_key_events" => 1022}})
    end
    latest = @day - 3
    add_period.call(latest, 75, ["approved"])
    add_period.call(latest - 1, 74, ["approved"])
    add_period.call(latest - 28, 60, ["approved"])
    add_period.call(latest + 1, 500, ["different"])
    assert_includes texts(evidence("How is GA4 traffic?")), "Sharing with the assistant is off"
    @setting.update!(share_google: true)
    bundle = evidence("How is GA4 traffic?")
    text = texts(bundle)
    assert_includes text, "75 sessions"
    assert_includes text, "60 sessions"
    assert_includes text, "15 higher"
    assert_includes text, "unvalidated as enquiries"
    assert_no_match(/74 sessions|500 sessions|945623878|utm_secret|1022/, text)
    assert visible?(bundle)
    connection.update!(grant_key: SecureRandom.uuid)
    assert_not visible?(bundle)
    next_bundle = evidence("GA4 traffic?")
    @setting.update!(share_google: false)
    assert_not visible?(next_bundle)
  end

  test "a GSC final national average and a Semrush campaign reading have separate consent, dates, scopes and sources" do
    Tracking::Enrollment.call(site: @site, phrase: "pump repair", devices: ["mobile"])
    connection = @site.create_search_console_connection!(property: "sc-domain:example.test", status: "connected")
    date = @day - 2
    SearchConsole::DailyPositions.persist!(site: @site, property: connection.property, country: "GBR",
      terms: ["pump repair"], start_day: date, end_day: date,
      rows: [{"keyword" => "pump repair", "date" => date.iso8601, "impressions" => 16, "clicks" => 2, "average_position" => 7.5}])
    @site.source_snapshots.create!(provider: "semrush", external_id: "example-report", keyword: "pump repair", observed_on: date, title: "Report",
      scope: "Example Town, mobile", source_url: "https://www.semrush.com/tracking/overview/123_456.html?domain_1=example.test",
      metrics: {series_method: Semrush::CampaignDashboard::METHOD, campaign_id: "123_456", domain: @site.host,
        location: @site.location, device: "mobile", language: "en", engine: "google",
        latest_date: date.iso8601, latest_position: 8, latest_feature: "Local pack", previous_date: (@day - 5).iso8601, previous_position: 12})
    @setting.update!(share_google: true)
    gsc = evidence("Search Console averages for pump repair")
    assert_includes texts(gsc), "#{date}, GBR, Google web search, all devices"
    assert_includes texts(gsc), "average position 7.5, 16 impressions and 2 clicks"
    assert_no_match(/feature-inclusive/, texts(gsc))
    assert visible?(gsc)
    connection.update!(ai_grant_revision: SecureRandom.uuid)
    assert_not visible?(gsc)
    assert_includes texts(evidence("Semrush campaign positions")), "Sharing with the assistant is off"
    @setting.update!(share_semrush: true)
    campaign = evidence("Semrush campaign positions")
    assert_includes texts(campaign), "position 8 in Semrush's feature-inclusive campaign"
    assert_includes texts(campaign), "Numeric baseline 12"
    assert visible?(campaign)
    @site.source_snapshots.where(provider: "semrush").delete_all
    assert_not visible?(campaign)
  end

  test "a revised owner brief and a removed scan cannot be reused in history" do
    @setting.update!(services: "Boiler replacement", share_maps: true)
    brief = evidence("What services matter?")
    assert visible?(brief)
    @setting.update!(services: "Commercial boiler maintenance")
    assert_not visible?(brief)
    @site.source_snapshots.create!(provider: "Local Falcon", external_id: "12345678901abcd", observed_on: @day - 1, keyword: "boiler",
      title: "Past scan", source_path: "private/archive.csv", scope: "Google Maps", metrics: {grid_size: 5, solv: 20.0})
    @site.source_snapshots.create!(provider: "Local Falcon", external_id: "12345678901abce", observed_on: @day, keyword: "boiler",
      title: "New scan", source_path: "private/archive.csv", scope: "Google Maps", metrics: {grid_size: 5, solv: 28.0})
    result = evidence("How did Maps look yesterday?")
    assert_includes texts(result), "Share of local voice 20.0%"
    assert_no_match(/28.0|archive.csv/, texts(result))
    assert visible?(result)
    @site.source_snapshots.where(observed_on: @day - 1).delete_all
    assert_not visible?(result)
  end

  test "cached Business Profile facts expire on their original clock even when the source is overwritten" do
    @setting.update!(share_google: true, share_maps: true)
    connection = @site.create_local_falcon_connection!(place_id: "exampleplace1234", verified_name: "Example", status: "connected")
    snapshot = @site.source_snapshots.create!(provider: "Google Business Profile", external_id: SourceSnapshot::GBP_CACHE_ID,
      title: "Profile", scope: "private", observed_on: @day, metrics: {"place_id" => connection.place_id, "start" => (@day - 31).iso8601,
        "end" => (@day - 4).iso8601, "totals" => {"CALL_CLICKS" => 12, "WEBSITE_CLICKS" => 34}})
    bundle = evidence("What are my Maps and business profile interactions?")
    assert_includes texts(bundle), "12 call clicks"
    assert visible?(bundle)
    travel_to((@day + 28).noon) { snapshot.touch }
    travel_to((@day + 29).noon)
    assert_not visible?(bundle)
    revised = evidence("Maps and business profile interactions?", day: @day + 29)
    assert visible?(revised)
    connection.destroy!
    @site.create_local_falcon_connection!(place_id: "exampleplace1234", verified_name: "Example", status: "connected")
    assert_not visible?(revised)
  end
end
