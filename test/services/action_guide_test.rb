require "test_helper"

class ActionGuideTest < ActiveSupport::TestCase
  setup do
    workspace = Workspace.create!(name: "Guide workspace")
    @site = workspace.sites.create!(name: "North Bakery", host: "bakery.example", location: "Bath")
    keyword = Tracking::Enrollment.call(site: @site, phrase: "fresh bread", preferred_url: "https://bakery.example/fresh-bread/", devices: ["desktop"])
    @series = keyword.tracking_series.sole
    @evidence = { "source" => "manual", "winning_url" => "https://www.bakery.example/bread-story/",
      "preferred_url" => "https://bakery.example/fresh-bread/", "position" => 6 }
  end

  def create_action(kind = "page_match", evidence: @evidence)
    @series.keyword_actions.create!(kind: kind, status: "open", observed_on: Date.current,
      title: "Review reading", description: "Test action", evidence: evidence)
  end

  def guide(action, draft: ActionDraft.current_for(action), historical: false)
    SeoSkills::ActionGuide.new(action: action, draft: draft, historical: historical)
  end

  test "owner can choose either page and copy the saved measurement and a specific task" do
    item = create_action
    result = guide(item)
    assert result.supported?
    assert_includes result.steps.flatten.join(" "), "Change preferred page"
    assert_includes result.steps.flatten.join(" "), "already links"
    task = result.handoff
    [@site.host, @site.name, "fresh bread", "desktop", "Bath", "Manual import", Date.current.iso8601,
      @evidence["winning_url"], @evidence["preferred_url"], "position — 6", "existing link", "placement for approval"].each { |value| assert_includes task, value }
    assert_equal task, guide(item, draft: nil).handoff
  end

  test "keeping the preferred page creates a self-contained link task from the owner's decision" do
    item = create_action
    receipt = ActionDraft.current_for(item)
    receipt.update!(owner_choice: "keep_preferred", owner_choice_note: "Look at the ordering paragraph.")
    result = guide(item)
    assert_predicate result, :choice_available?
    assert_equal "Keep the page I chose in Searchdesk", result.saved_choice_label
    [@site.name, "fresh bread", @evidence["winning_url"], @evidence["preferred_url"], receipt.owner_choice_note,
      "main text", "exact linked words and their location", "That completes the task", "section and paragraph",
      "current and proposed sentence", "destination URL", "approval before editing"].each { |value| assert_includes result.handoff, value }
    assert_not_includes result.handoff, "recommend which"
    assert_not_includes result.handoff, "Change preferred page"
    assert_not_includes result.handoff, "position —"
  end

  test "choosing the ranking page prepares a tracking task and leaves the saved keyword preference intact" do
    item = create_action
    ActionDraft.current_for(item).update!(owner_choice: "prefer_ranking")
    result = guide(item)
    assert_includes result.handoff, "choose Change preferred page"
    assert_not_includes result.handoff, "draft one change"
    assert_equal @evidence["preferred_url"], item.keyword.reload.preferred_url
  end

  test "verified link evidence replaces the manual investigation in the owner handoff" do
    action = create_action
    draft = ActionDraft.current_for(action)
    draft.update!(owner_choice: "keep_preferred", owner_choice_note: "We think it is missing.",
      link_checked_at: Time.utc(2026, 11, 25, 10, 34), link_check_result: {
        "outcome" => "contextual", "anchor" => "Order bread", "section" => "Fresh from our oven"
      })
    result = guide(action)
    assert_predicate result, :link_check_available?
    assert_equal "Keep the existing link", result.saved_link_finding.heading
    [@evidence["winning_url"], @evidence["preferred_url"], "10:34", "Order bread", "Fresh from our oven",
      "Leave this link in place"].each { |text| assert_includes result.handoff, text }
    assert_not_includes result.handoff, draft.owner_choice_note
    assert_not_includes result.handoff, "draft one change"
  end

  test "a finding before the owner chooses records the evidence without choosing which page to keep" do
    action = create_action
    ActionDraft.current_for(action).update!(link_check_result: {"outcome" => "contextual", "anchor" => "Fresh bread"}, link_checked_at: Time.current)
    result = guide(action)
    assert_predicate result, :link_check_available?
    assert_includes result.handoff, "Confirm which page"
    assert_not_includes result.handoff, "The owner chose"
  end

  test "handoff distinguishes navigation, missing links, broken targets and an inconclusive check" do
    action = create_action
    draft = ActionDraft.current_for(action)
    draft.update!(owner_choice: "keep_preferred", link_checked_at: Time.current)
    [
      [{"outcome" => "navigation_only", "placement" => "Footer", "anchor" => "Bread"}, "Consider a link in the main text", "footer", "one draft"],
      [{"outcome" => "missing"}, "Review one possible link", "public HTML", "one draft"],
      [{"outcome" => "broken_target", "target_status" => 410}, "Fix the destination first", "HTTP 410", "working replacement"],
      [{"outcome" => "unverifiable", "reason" => "The page could not be read."}, "Unable to verify the link", "could not be read", "as a visitor"]
    ].each do |data, title, evidence, instruction|
      draft.update!(link_check_result: data)
      result = guide(action)
      assert_equal title, result.saved_link_finding.heading
      assert_includes result.handoff, evidence
      assert_includes result.handoff, instruction
      assert_not_includes result.handoff, "Leave this link in place"
    end
    historical = guide(action, historical: true)
    refute_predicate historical, :link_check_available?
    assert historical.saved_link_finding
    assert_not_includes historical.handoff, "could not be read"
    draft.update!(owner_choice: "prefer_ranking")
    refute_predicate guide(action), :link_check_available?
    assert_includes guide(action).handoff, "Change preferred page"
  end

  test "an earlier or ineligible decision remains readable without handing off its old instructions" do
    item = create_action
    receipt = ActionDraft.current_for(item)
    receipt.update!(owner_choice: "keep_preferred", owner_choice_note: "Note about the earlier result.")
    result = guide(item, historical: true)
    assert_equal "Keep the page I chose in Searchdesk", result.saved_choice_label
    refute_predicate result, :choice_available?
    assert_not_includes result.handoff, receipt.owner_choice_note
    assert_includes result.handoff, "latest complete result"
    refute_predicate guide(item, draft: nil), :choice_available?
    item.keyword.update!(preferred_url: "https://bakery.example/collection/")
    refute_predicate guide(item), :choice_available?
  end

  test "legacy receipt with no snapshot uses the action and a saved receipt never borrows newly recorded URLs" do
    item = create_action
    old = ActionDraft.current_for(item)
    item.update!(evidence: @evidence.merge("winning_url" => "https://bakery.example/later/"))
    assert_equal @evidence["winning_url"], guide(item, draft: old).winning_url
    old.update!(input_snapshot: {})
    assert_equal item.evidence["winning_url"], guide(item, draft: old).winning_url
  end

  test "missing, off-site or unsafe pages give an evidence check instead of an edit" do
    item = create_action
    ["https://bakery.example.evil.test/", "javascript:alert(1)", "https://name@bakery.example/secret",
      "https://bakery.example:8443/account", nil].each do |value|
      item.update!(evidence: @evidence.merge("winning_url" => value))
      result = guide(item)
      assert_nil result.winning_url
      refute_predicate result, :choice_available?
      assert_includes result.headline, "Confirm the two pages"
      assert_not_includes result.handoff, value if value
    end
  end

  test "a later page choice prompts a fresh check and leaves the historical URLs intact" do
    item = create_action
    item.keyword.update!(preferred_url: "https://bakery.example/new/")
    result = guide(item)
    assert_includes result.meaning, "setting has changed"
    assert_includes result.handoff, "after the setting changed"
    assert_equal @evidence["preferred_url"], result.preferred_url
    assert_not_includes result.handoff, "/new/"
  end

  test "older, reviewed and demo observations receive context-specific work requests" do
    item = create_action
    assert_includes guide(item, historical: true).handoff, "latest complete result"
    item.update!(status: "resolved")
    assert_includes guide(item).handoff, "later checks"
    item.update!(evidence: @evidence.merge("source" => "demo"))
    assert_includes guide(item).meaning, "simulated"
    refute_predicate guide(item), :choice_available?
    assert_includes guide(item).handoff, "demonstration only"
  end

  test "a decline calls for comparing the actual history and working through both outcomes" do
    item = create_action("rank_drop", evidence: @evidence.merge("baseline_observation_id" => 15,
      "previous_observation_id" => 16, "observation_id" => 17))
    result = guide(item)
    refute_predicate result, :choice_available?
    assert_includes result.meaning.downcase, "two days"
    assert_includes result.steps.flatten.join(" "), "If the same page appeared"
    assert_includes result.handoff, "starting check"
    assert_includes result.handoff, "monitoring"
    item.update!(evidence: @evidence)
    assert_includes guide(item).headline, "history first"
  end
end
