require "test_helper"

class KeywordTrackingTest < ActiveSupport::TestCase
  setup do
    @site = Workspace.create!(name: "First workspace").sites.create!(
      name: "Heating", host: "example.test", language: "en", location: "Sample town",
      time_zone: "Europe/London", tracking_mode: "manual")
  end

  def enroll(phrase: "heating service", devices: ["mobile"])
    Tracking::Enrollment.call(site: @site, phrase: phrase, preferred_url: "https://example.test/heating", devices: devices)
  end

  def payload(series, day, count: 30, win: nil)
    items = (1..count).map do |rank|
      url = rank == win ? "https://www.example.test/other" : "https://result-#{rank}.invalid/"
      { "type" => "organic", "rank_group" => rank, "url" => url }
    end
    { "source" => "manual", "keyword" => series.keyword.phrase, "host" => @site.host,
      "language" => @site.language, "location" => @site.location, "device" => series.device, "depth" => 30,
      "captured_at" => "#{day.iso8601}T08:00:00Z", "items" => items }
  end

  test "import freezes first result and records date, coverage, page and evidence separately" do
    first_day = Date.new(2026, 3, 28)
    travel_to Time.utc(2026, 3, 28, 10) do
      series = enroll.tracking_series.first
      data = payload(series, first_day, win: 18)
      data["items"].unshift({ "type" => "local_pack", "rank_group" => 1, "url" => "https://example.test/" })
      check = Tracking::ManualImport.call(series: series, payload: data.to_json)
      assert_equal 18, check.position
      assert_nil check.preferred_position
      assert_equal check, series.reload.baseline_observation
      assert_equal check, Tracking::ManualImport.call(series: series, payload: data)
      assert_equal :baseline, Tracking::Dashboard.rows(site: @site, date: first_day, device: "mobile").sole[:transition]
      assert_equal check.id, series.keyword_actions.sole.evidence["observation_id"]
      assert_raises(Tracking::ManualImport::Error) { Tracking::ManualImport.call(series: series, payload: data.merge("location" => "Different")) }
    end
    travel_to Time.utc(2026, 3, 30, 10) do
      series = @site.keywords.first.tracking_series.first
      day = Date.new(2026, 3, 30)
      Tracking::ManualImport.call(series: series, payload: payload(series, day, win: 10))
      assert_equal first_day, series.reload.baseline_observation.day
      row = Tracking::Dashboard.rows(site: @site, date: day, device: "mobile").sole
      assert_equal [10, 18, 8, :up], row.values_at(:rank, :baseline_rank, :change, :transition)
      missing = Tracking::Dashboard.rows(site: @site, date: day - 1, device: "mobile").sole
      assert_equal ["missing", nil, first_day], missing.values_at(:status, :rank, :as_of)
      assert_equal 2, RankObservation.count
    end
  end

  test "coverage gaps are not ranked and outside-range baseline is valid" do
    travel_to Time.utc(2026, 11, 2, 12) do
      series = enroll.tracking_series.first
      sample = payload(series, Date.current, win: 18)
      sample["items"].delete_at(3)
      partial = Tracking::ManualImport.call(series: series, payload: sample)
      assert_equal ["incomplete", 3, nil], [partial.status, partial.coverage, partial.position]
      assert_nil series.reload.baseline_observation
      full = Tracking::ManualImport.call(series: series, payload: payload(series, Date.current))
      assert_equal ["outside", 30], [full.status, full.coverage]
      assert_equal full.id, series.reload.baseline_observation_id
    end
    travel_to Time.utc(2026, 11, 3, 12) do
      series = @site.keywords.first.tracking_series.first
      Tracking::ManualImport.call(series: series, payload: payload(series, Date.current, win: 7))
      assert_equal [:entered, nil], Tracking::Dashboard.rows(site: @site, device: "mobile", date: Date.current).sole.values_at(:transition, :change)
    end
  end

  test "configuration changes archive the old series and leave other tenants alone" do
    old = enroll.tracking_series.current.sole
    @site.update!(location: "Elsewhere")
    new_series = enroll.tracking_series.current.sole
    assert_not_equal old.id, new_series.id
    assert_predicate old.reload.archived_at, :present?
    another = Workspace.create!(name: "Second workspace").sites.create!(name: "Other", host: "example.test", location: "Elsewhere", language: "en", time_zone: "UTC", tracking_mode: "manual")
    assert_empty Tracking::Dashboard.rows(site: another, date: Date.current, device: "mobile")
  end

  test "demo history is explicitly sourced and repeatable; manual sites reject simulation" do
    assert_raises(ArgumentError) { Tracking::DemoHistory.call(site: @site) }
    @site.update!(tracking_mode: "demo")
    keyword = enroll(devices: %w[mobile desktop])
    assert_equal 14, RankObservation.where(source: "demo").count
    assert_equal 2, keyword.tracking_series.current.count
    assert_no_difference "RankObservation.count" do
      Tracking::DemoHistory.call(site: @site)
      enroll(devices: %w[mobile desktop])
    end
    assert RankObservation.all.all? { |o| o.evidence["source_label"] == "Simulated demonstration" }
  end

  test "current day is taken from capture location and imports require an offset" do
    travel_to Time.utc(2026, 3, 29, 23, 45) do
      series = enroll.tracking_series.first
      sample = payload(series, Date.new(2026, 3, 30), win: 4).merge("captured_at" => "2026-03-29T23:35:00Z")
      assert_equal Date.new(2026, 3, 30), Tracking::ManualImport.call(series: series, payload: sample).day
      assert_raises(Tracking::ManualImport::Error) { Tracking::ManualImport.call(series: series, payload: sample.merge("captured_at" => "2026-03-29T23:35:00")) }
    end
  end
end
