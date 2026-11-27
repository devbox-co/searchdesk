require "test_helper"

class CompetingPageAdviceTest < ActiveSupport::TestCase
  setup do
    @site = Workspace.create!(name: "York").sites.create!(name: "Repairs", host: "repairs.example",
      location: "York", tracking_mode: "manual", rank_country_code: "GB")
    @site.create_search_console_connection!(property: "sc-domain:repairs.example", status: "connected")
    @keyword = @site.keywords.create!(phrase: "heating repair")
    @setting = @site.create_ai_setting!(enabled: true, share_google: true)
    @evidence = {"query" => @keyword.phrase, "device" => "mobile", "country" => "GBR", "property" => "sc-domain:repairs.example",
      "pages" => %w[https://repairs.example/ https://repairs.example/service], "weeks" => [],
      "switch_count" => 1, "level" => "watch",
      "clicks" => {"previous" => 3, "current" => 1, "previous_impressions" => 28, "current_impressions" => 75,
        "previous_start" => "2026-09-28", "previous_end" => "2026-10-25", "current_start" => "2026-10-26",
        "current_end" => "2026-11-22", "trend" => "down", "material_decline" => false}}
    @finding = SiteFinding.create!(site: @site, keyword: @keyword, kind: "competing_pages", level: "watch",
      fingerprint: "pair", evidence: @evidence, active: true)
  end

  def build
    CompetingPages::Advice.build(finding: @finding, setting: @setting)
  end

  def render(key, facts, ids)
    AiAssistant::Recipe.render({"decision_key" => key, "fact_ids" => ids}, facts, kind: "page_advice")
  end

  test "small click loss with a single switch supports checking intent and monitoring" do
    evidence = build
    facts = evidence.fetch("facts")
    assert_equal %w[check_new_leader monitor], facts.first["eligible_decisions"]
    answer = render("check_new_leader", facts, ["F1"])
    assert_equal ["monitor", "Monitor for now"], answer.values_at("owner_choice", "decision")
    assert_match(/few clicks/, answer["reason"])
    assert_match(/opening paragraph/, answer["next_step"])
    assert_match(/next complete week/, answer["revisit"])
    assert_equal %w[F1 F2], answer["fact_ids"]
    assert facts.all? { |f| f["url"].start_with?("/competing_pages/#{@finding.id}#cp-") }
    assert_nil render("consolidate", facts, ["F1"])
    assert_nil render("inspect_listing", facts, ["F1"])
    assert_nil render("monitor", facts, ["F99"])
    assert_nil render("monitor", facts, ["F1", "F1"])
    assert_equal [@finding.id], evidence.dig("access", "records", "findings")
  end

  test "stable lead and worsening click share send bounded relevant SEO options and verified facts" do
    @evidence["switch_count"] = 0
    @evidence["clicks"].merge!("previous" => 16, "current" => 9, "previous_impressions" => 111,
      "current_impressions" => 210, "material_decline" => true)
    @evidence["query"] = "heating repair agent@example.com sk-test-0123456789abcd"
    @finding.update!(evidence: @evidence)
    evidence = build
    prepared = AiAssistant::OpenaiClient.prepare(kind: "page_advice", evidence: evidence, question: nil)
    request = JSON.parse(prepared.json)
    assert_equal false, request["store"]
    assert_equal "competing_page_decision_v2", request.dig("text", "format", "name")
    assert_equal ["decision_key"], request.dig("text", "format", "schema", "required")
    assert_equal ["decision_key"], request.dig("text", "format", "schema", "properties").keys
    assert_equal ["competing-pages-v1"], prepared.playbook_keys
    assert_operator prepared.reservation_microusd, :>, 0
    assert_equal %w[inspect_listing check_listing_position], request.dig("text", "format", "schema", "properties", "decision_key", "enum")
    assert_no_match(/agent@example|0123456789abcd|repairs\.example|competing_pages\/|grants|fingerprint/, prepared.json)
    context = JSON.parse(request["input"])
    assert_equal %w[GBR mobile], context["search"].values_at("country", "device")
    assert_equal %w[2026-10-26 2026-11-22], context["search"]["current_period"]
    assert_match(/16 to 9/, context["facts"].second["text"])
    assert_match(/111.*210/, context["facts"].third["text"])
    answer = AiAssistant::Recipe.render({"decision_key" => "inspect_listing"}, prepared.facts, kind: "page_advice")
    assert_equal answer, render("inspect_listing", prepared.facts, ["F2"])
    assert_nil AiAssistant::Recipe.render({"decision_key" => "inspect_listing", "new_facts" => "extra"}, prepared.facts, kind: "page_advice")
    assert_equal %w[F1 F2 F3], answer["fact_ids"]
    assert_equal "open", answer["owner_choice"]
    assert_match(/smaller share/, answer["reason"])
    assert_match(/title and description in Google on mobile/, answer["next_step"])
    assert_nil render("check_new_leader", prepared.facts, ["F1"])
    assert_equal answer, AiAssistant::Recipe.fallback(prepared.facts, kind: "page_advice")
  end

  test "address variants support verification and limited evidence only supports waiting" do
    @evidence["pages"] = %w[https://repairs.example/service https://www.repairs.example/service/]
    @finding.update!(evidence: @evidence, level: "limited")
    facts = build.fetch("facts")
    assert_equal %w[verify_addresses monitor], facts.first["eligible_decisions"]
    assert_match(/developer/, render("verify_addresses", facts, ["F1"])["next_step"])
    @evidence["pages"][1] = "https://repairs.example/guide"
    @evidence["clicks"].merge!("previous" => nil, "trend" => "unknown")
    @finding.update!(evidence: @evidence)
    facts = build.fetch("facts")
    assert_equal ["monitor"], facts.first["eligible_decisions"]
    assert_match(/too few weekly click totals/, facts.second["text"])
  end

  test "changing evidence changes the receipt digest while a user decision or key order does not" do
    old = CompetingPages::Advice.digest(@finding)
    @finding.update!(disposition: "monitor", evidence: @evidence.to_a.reverse.to_h)
    assert_equal old, CompetingPages::Advice.digest(@finding)
    @finding.evidence["clicks"]["previous"] = 8
    assert_not_equal old, CompetingPages::Advice.digest(@finding)
  end

  test "turning off Google sharing prevents preparing an advice payload" do
    @setting.update!(share_google: false)
    assert_raises(ArgumentError) { build }
  end
end
