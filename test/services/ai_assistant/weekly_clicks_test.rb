require "test_helper"

class WeeklyClicksTest < ActiveSupport::TestCase
  setup do
    @site = Workspace.create!(name: "Studio").sites.create!(name: "Studio", host: "studio.example",
      location: "Reading", rank_country_code: "GB", time_zone: "Europe/London")
    @setting = @site.create_ai_setting!(enabled: true, share_google: true)
    @connection = @site.create_search_console_connection!(property: "sc-domain:studio.example", status: "connected")
    @finish = Date.new(2026, 11, 5)
    travel_to((@finish + 3).noon)
    @phrases = ["lamp repair", "boiler servicing", "heating repairs"]
    @phrases.each { |phrase| @site.keywords.create!(phrase: phrase) }
    @days = ((@finish - 13)..@finish).to_a
    @values = @phrases.product(@days).filter_map do |phrase, day|
      next if phrase == "heating repairs" && day == @days[2]
      count = case phrase
      when "lamp repair" then day <= @finish - 7 ? 1 : 0
      when "boiler servicing" then day <= @finish - 7 ? 0 : 2
      else 25
      end
      { "keyword" => phrase, "date" => day.iso8601, "clicks" => count, "impressions" => 100, "average_position" => 5 }
    end
    persist(@connection.property, "GBR", @values)
  end

  def persist(property, country, values)
    SearchConsole::DailyPositions.persist!(site: @site, property: property, country: country, terms: @phrases,
      start_day: @days.first, end_day: @days.last, rows: values)
  end

  def evidence(question: nil, day: @finish)
    AiAssistant::Evidence.build(site: @site, setting: @setting, question: question, kind: question ? "question" : "brief", day: day)
  end

  def weekly(bundle)
    bundle.fetch("facts").find { |fact| fact["source"] == "Weekly search clicks" }
  end

  test "daily brief compares two full windows, cites all participating receipts and preserves reported zero" do
    persist("sc-domain:wrong.example", "GBR", @values.map { |v| v.merge("clicks" => 999) })
    persist(@connection.property, "USA", @values.map { |v| v.merge("clicks" => 888) })
    bundle = evidence
    result = weekly(bundle)
    assert_includes result["text"], "2026-10-23 to 2026-10-29 with 2026-10-30 to 2026-11-05"
    assert_includes result["text"], "2 of 3 tracked searches"
    assert_includes result["text"], "“lamp repair” fell from 7 to 0 clicks"
    assert_includes result["text"], "“boiler servicing” rose from 0 to 14 clicks"
    assert_no_match(/heating repairs|999|888/, result["text"])
    assert_includes result["url"], "/source_snapshots?"
    ids = SearchConsole::DailyPositions.scope_for(@site).where("metrics->>'property' = ?", @connection.property).ids
    assert_equal 6, ids.size
    assert_equal ids.sort, bundle.dig("access", "records", "snapshots").sort
    assert_equal @site.keywords.ids.sort, bundle.dig("access", "records", "keywords").sort
    assert AiAssistant::Evidence.visible?(site: @site, setting: @setting, evidence: bundle)
    @connection.update!(ai_grant_revision: SecureRandom.uuid)
    assert_not AiAssistant::Evidence.visible?(site: @site, setting: @setting, evidence: bundle)
  end

  test "weekly questions respect the named keyword, reporting date, Google grant and site sharing" do
    question = "How did weekly search clicks change for lamp repair?"
    result = evidence(question: question)
    assert_includes weekly(result)["text"], "1 of 1 tracked search"
    assert_no_match(/boiler servicing|heating repairs/, weekly(result)["text"])
    assert_includes weekly(result)["url"], "keyword=lamp+repair"
    assert_equal [@site.keywords.find_by!(phrase: "lamp repair").id], result.dig("access", "records", "keywords")
    historic = weekly(evidence(question: question, day: @finish - 1))
    assert_includes historic["text"], "2026-11-04"
    assert_includes historic["text"], "0 of 1 tracked search"
    assert_nil weekly(evidence(question: "Which searches lost mobile clicks this week?"))
    @setting.update!(share_google: false)
    assert_nil weekly(evidence(question: question))
    assert_not AiAssistant::Evidence.visible?(site: @site, setting: @setting, evidence: result)
    @setting.update!(share_google: true)
    @connection.update!(status: "reconnect")
    assert_nil weekly(evidence(question: question))
  end

  test "the suggested weekly investigation covers the watchlist even when its wording contains a tracked phrase" do
    @site.keywords.create!(phrase: "this week")
    @site.keywords.create!(phrase: "Lamp Repair")
    bundle = evidence(question: AiAssistant::Playbooks.find("weekly_clicks").question)
    assert_equal ["Weekly search clicks"], bundle.fetch("facts").pluck("source")
    assert_includes weekly(bundle)["text"], "2 of 4 tracked searches"
    assert_equal @site.keywords.ids.sort, bundle.dig("access", "records", "keywords").sort
    @setting.update!(share_google: false)
    assert_empty evidence(question: AiAssistant::Playbooks.find("weekly_clicks").question).fetch("facts")
  end
end
