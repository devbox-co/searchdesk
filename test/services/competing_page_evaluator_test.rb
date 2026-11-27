require "test_helper"

class CompetingPageEvaluatorTest < ActiveSupport::TestCase
  PROPERTY = "sc-domain:heating.example"
  A = "https://heating.example/service"
  B = "https://heating.example/guide"
  C = "https://heating.example/other"
  START = Date.new(2026, 9, 28)

  setup do
    travel_to Time.utc(2026, 11, 26, 12)
    @site = Workspace.create!(name: "Town").sites.create!(name: "Town Heating", host: "heating.example",
      location: "York", tracking_mode: "manual", rank_country_code: "GB")
    @site.create_search_console_connection!(property: PROPERTY, status: "connected", data_through: Date.new(2026, 11, 23))
    @keyword = @site.keywords.create!(phrase: "boiler repair", preferred_url: A)
  end

  def save_week(index, scores, clicks: 0, impressions: 50, partial: false, device: "mobile", country: "GBR")
    pages = scores.map do |url, impressions|
      {"url" => url, "impressions" => impressions, "clicks" => 0, "position" => 3}
    end
    SearchConsolePageWeek.create!(site: @site, property: PROPERTY, country: country, query: @keyword.phrase,
      device: device, week_start: START + 7 * index, pages: pages, clicks: clicks, impressions: impressions, partial: partial)
  end

  def evaluate
    CompetingPages::Evaluator.call(site: @site, property: PROPERTY, country: "GBR")
    SiteFinding.competing_pages.current.where(site: @site)
  end

  test "recurring swaps and explicit zero click counts use two matched four-week property periods" do
    [A, A, B, B, A, A, B, A].each_with_index do |leader, i|
      save_week(i, {leader => 25, (leader == A ? B : A) => 9}, clicks: i < 4 ? 6 : 0)
    end
    save_week(7, {C => 500}, clicks: 20, device: "desktop")
    save_week(7, {C => 500}, clicks: 20, country: "USA")
    finding = evaluate.sole
    assert_equal ["review", "open", @keyword.id], [finding.level, finding.disposition, finding.keyword_id]
    e = finding.evidence
    assert_equal 4, e["switch_count"]
    assert_equal [A, B].sort, e["pages"]
    assert_equal [A, A, B, B, A, A, B, A], e["weeks"].pluck("leader_url")
    assert_equal [24, 0, -24, "down"], e["clicks"].values_at("previous", "current", "change", "trend")
    assert_equal %w[2026-09-28 2026-10-25 2026-10-26 2026-11-22], e["clicks"].values_at("previous_start", "previous_end", "current_start", "current_end")
    finding.update!(disposition: "accepted_overlap")
    assert_no_changes -> { finding.reload.updated_at } do
      assert_equal finding.id, evaluate.sole.id
    end
    assert_equal "accepted_overlap", finding.reload.disposition
  end

  test "ties sparse receipts gaps and third pages interrupt the original pair sequence" do
    save_week(0, {A => 10})
    save_week(1, {B => 12})
    save_week(2, {B => 10, A => 10})
    save_week(3, {A => 1})
    save_week(5, {C => 35})
    save_week(6, {A => 14})
    save_week(7, {B => 21, A => 3})
    finding = evaluate.sole
    assert_equal "watch", finding.level
    assert_equal 1, finding.evidence["switch_count"]
    assert_equal %w[leader leader tie sparse unreported leader leader leader], finding.evidence["weeks"].pluck("state")
    assert_equal [0, nil, "unknown"], finding.evidence["clicks"].values_at("previous", "current", "trend")
  end

  test "partial receipts cannot produce a leader even if the available pages appear decisive" do
    save_week(0, {A => 21}, clicks: 12)
    save_week(1, {B => 50}, partial: true)
    save_week(2, {A => 22})
    save_week(7, {A => 12}, clicks: nil)
    e = evaluate.sole.evidence
    assert_equal "limited", e["level"]
    assert_equal 0, e["switch_count"]
    assert_equal ["partial", nil, 0], e["weeks"][1].values_at("state", "leader_url", "clicks")
    assert_equal "unknown", e["clicks"]["trend"]
  end

  test "URL variants with unconfirmed equivalence require verification before a competition review" do
    [A, A + "/", A, A + "/"].each_with_index { |url, i| save_week(i, {url => 12}) }
    e = evaluate.sole.evidence
    assert_equal "limited", e["level"]
    assert_match(/redirects/, e["recommendation"])
  end

  test "new material evidence reopens a pair and different evidence retires it" do
    save_week(2, {A => 13, B => 9})
    save_week(3, {A => 16, B => 9})
    old = evaluate.sole
    old.update!(disposition: "monitor")
    save_week(4, {B => 20, A => 9})
    save_week(5, {A => 20, B => 9})
    updated = evaluate.sole
    assert_equal [old.id, "review", "open"], [updated.id, updated.level, updated.disposition]
    SearchConsolePageWeek.where(site: @site).delete_all
    save_week(6, {B => 25, C => 9})
    save_week(7, {C => 20, B => 8})
    assert_not_equal old.id, evaluate.sole.id
    assert_not old.reload.active?
  end

  test "one eligible URL never creates a finding and future or foreign data is ignored" do
    save_week(6, {A => 20, "https://unrelated.example/unsafe" => 9})
    save_week(7, {A => 20})
    save_week(8, {B => 100})
    assert_empty evaluate
    @site.search_console_connection.update!(property: "sc-domain:replacement.example")
    assert_nil CompetingPages::Evaluator.call(site: @site, property: PROPERTY, country: "GBR")
  end

  test "old weeks cannot keep a finding current after both pages drop out of the reporting period" do
    [A, B, A].each_with_index { |url, i| save_week(i, {url => 12}) }
    finding = evaluate.sole
    travel_to(Time.utc(2027, 1, 28, 12))
    @site.search_console_connection.update!(data_through: Date.new(2027, 1, 25))
    assert_empty evaluate
    assert_not finding.reload.active?
  end

  test "tiny differences at high impressions break the sequence" do
    save_week(4, {A => 100, B => 91})
    save_week(5, {B => 100, A => 90})
    save_week(6, {A => 100, B => 90})
    save_week(7, {B => 500, A => 499})
    e = evaluate.sole.evidence
    assert_equal %w[tie leader leader tie], e["weeks"].last(4).pluck("state")
    assert_equal 1, e["switch_count"]
  end

  test "minor click fluctuations preserve an owner decision and a newly material decline reopens it" do
    [A, A, B, A, A, B, A, A].each_with_index { |url, i| save_week(i, {url => 15}, clicks: 5) }
    finding = evaluate.sole
    finding.update!(disposition: "accepted_overlap")
    latest = SearchConsolePageWeek.where(site: @site).order(week_start: :desc).first
    latest.update!(clicks: 4)
    assert_equal "accepted_overlap", evaluate.sole.disposition
    assert_equal "down", finding.reload.evidence.dig("clicks", "trend")
    latest.update!(clicks: 0)
    assert_equal "open", evaluate.sole.disposition
    assert_equal true, finding.reload.evidence.dig("clicks", "material_decline")
  end

  test "a single switch with few clicks points to the page that took the lead" do
    clicks = [1, 1, 1, 0, 0, 1, 0, 0]
    impressions = [7, 7, 7, 7, 18, 18, 19, 20]
    [A, A, A, A, A, B, B, B].each_with_index do |url, i|
      save_week(i, {url => impressions[i]}, clicks: clicks[i], impressions: impressions[i])
    end
    e = evaluate.sole.evidence
    assert_equal ["watch", 1, B], e.values_at("level", "switch_count", "recommended_page_url")
    assert_equal [3, 1, 28, 75], e["clicks"].values_at("previous", "current", "previous_impressions", "current_impressions")
    assert_match(/page that took the lead/, e["recommendation"])
    assert_match(/few clicks.*next week/, e["recommendation"])
  end

  test "falling clicks without a switch direct the owner to the snippet when appearances rise" do
    [27, 28, 28, 28, 50, 50, 55, 55].each_with_index do |impressions, i|
      save_week(i, {A => impressions, B => 8}, clicks: [4, 4, 4, 4, 2, 2, 2, 3][i], impressions: impressions)
    end
    e = evaluate.sole.evidence
    assert_equal ["watch", 0, nil], e.values_at("level", "switch_count", "recommended_page_url")
    assert_equal [16, 9, 111, 210], e["clicks"].values_at("previous", "current", "previous_impressions", "current_impressions")
    assert_match(/appeared more often/, e["recommendation"])
    assert_match(/title and description in Google/, e["recommendation"])
    latest = SearchConsolePageWeek.where(site: @site).order(week_start: :desc).first
    latest.update!(impressions: nil)
    e = evaluate.sole.evidence
    assert_equal [111, nil], e["clicks"].values_at("previous_impressions", "current_impressions")
    assert_match(/check whether/, e["recommendation"])
  end
end
