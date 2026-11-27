require "test_helper"
require "active_support/testing/constant_stubbing"

class ActionGuidanceTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::ConstantStubbing

  setup do
    workspace = Workspace.create!(name: "Westbridge")
    @site = workspace.sites.create!(name: "Westbridge Heating", host: "westbridge.example", location: "Harrogate",
      time_zone: "Europe/London", tracking_mode: "manual")
    owner = User.create!(email: "action-owner@example.test", password: "long-local-test-password")
    @membership = workspace.memberships.create!(user: owner, role: "owner")
    post login_path, params: { session: { email: owner.email, password: "long-local-test-password" } }

    @winning = "https://westbridge.example/advice/boiler-care/"
    @preferred = "https://westbridge.example/boiler-servicing/"
    @phrase = "boiler servicing harrogate"
  end

  test "a saved review opens directly with concrete choices and a portable brief using the captured pages" do
    series = enroll
    record_result(series, Time.current, 6)
    action = series.keyword_actions.find_by!(kind: "page_match")
    receipt = ActionDraft.current_for(action)
    original = receipt.attributes
    # A new preference must not rewrite the observation or the handoff about it.
    series.keyword.update!(preferred_url: "https://westbridge.example/new-service/")

    assert_no_difference(["ActionDraft.count", "AiRun.count", "WordingRun.count"]) do
      assert_no_enqueued_jobs { get action_draft_path(action) }
    end
    assert_response :success
    assert_equal original, receipt.reload.attributes
    [@winning, @preferred].each { |page| assert_select ".action-guide-pages a[href=?]", page }
    assert_select ".action-guide-steps li", minimum: 2
    assert_select "button[data-copy-handoff]", count: 1

    brief = handoff
    [@site.name, @site.host, @phrase, @winning, @preferred].each { |detail| assert_includes brief, detail }
    assert_match(/desktop/i, brief)
    assert_match(/Harrogate/, brief)
    refute_includes brief, "/new-service/"
  end

  test "a sustained decline gives guidance for two comparable readings and flags old evidence" do
    first = 4.days.ago
    series = travel_to(first) { enroll }
    record_result(series, first, 3)
    record_result(series, first + 1.day, 10)
    record_result(series, first + 2.days, 9)
    action = series.keyword_actions.find_by!(kind: "rank_drop")
    travel_to(first + 2.days + 1.minute) do
      get action_draft_path(action)
      assert_response :success
      assert_select ".action-guide-steps li", minimum: 2
      assert_match(/starting|baseline/i, handoff)
      assert_match(/two|consecutive/i, handoff)
      assert_select "p.notice", text: /more than a day old/, count: 0
    end

    get action_draft_path(action)
    assert_response :success
    assert_select "p.notice", text: /more than a day old/
    assert_select ".action-guide-steps li", minimum: 2
    brief = handoff
    assert_includes brief, @phrase
    assert_match(/two|consecutive|both|starting/i, brief)
    assert_match(/fresh|latest|recent|newer/i, brief)
    assert_match(/approve|approval/i, brief)
  end

  test "a saved review can be read by a viewer only for the selected site" do
    series = enroll
    record_result(series, Time.current, 4)
    action = series.keyword_actions.find_by!(kind: "page_match")
    @membership.update!(role: "viewer")
    get actions_path(keyword_id: series.keyword_id)
    assert_response :success
    assert_select "article#keyword_action_#{action.id} a[href=?]", action_draft_path(action), text: "View next steps"
    assert_select "form[action=?]", action_path(action), count: 0
    get action_draft_path(action)
    assert_response :success
    assert_includes handoff, @phrase
    post action_draft_path(action)
    assert_response :forbidden

    other = @site.workspace.sites.create!(name: "Other business", host: "other.example", location: "York")
    post select_site_path(other)
    get action_draft_path(action)
    assert_response :not_found
    refute_includes response.body, @winning
  end

  test "a legacy observation with unsuitable page addresses cannot offer them as links or copied instructions" do
    foreign = "https://unrelated.example/foreign-page/"
    unsuitable = "mailto:someone@westbridge.example"
    action = enroll.keyword_actions.create!(kind: "page_match", title: "Compare the two pages", description: "Review the saved reading",
      observed_on: Date.current, evidence: { "source" => "manual", "winning_url" => foreign, "preferred_url" => unsuitable })

    get action_draft_path(action)
    assert_response :success
    instructions = handoff
    [foreign, unsuitable].each do |value|
      assert_select "a[href=?]", value, count: 0
      refute_includes instructions, value
    end
  end

  test "a manager can revise a saved choice without altering the ranking receipt or keyword" do
    @membership.update!(role: "manager")
    series = enroll
    record_result(series, Time.current, 6)
    action = series.keyword_actions.find_by!(kind: "page_match")
    draft = ActionDraft.current_for(action)
    receipt = draft.slice(:input_snapshot, :input_digest, :instructions, :skill_version)

    assert_no_difference(["ActionDraft.count", "AiRun.count", "WordingRun.count"]) do
      assert_no_enqueued_jobs do
        with_link_checker do |calls|
          patch action_draft_choice_path(action), params: {draft_id: draft.id, owner_choice: "keep_preferred", owner_choice_note: " Confirm the article links here. "}
          assert_equal [{host: @site.host, source_url: @winning, target_url: @preferred}], calls
        end
      end
    end
    assert_redirected_to action_draft_path(action, anchor: "link-check")
    assert_equal "Confirm the article links here.", draft.reload.owner_choice_note
    assert_equal "keep_preferred", draft.owner_choice
    assert_equal "contextual", draft.link_check_result.fetch("outcome")
    assert draft.link_checked_at.present?

    patch action_draft_choice_path(action), params: {draft_id: draft.id, owner_choice: "prefer_ranking"}
    assert_redirected_to action_draft_path(action, anchor: "handoff-heading")
    assert_equal "prefer_ranking", draft.reload.owner_choice
    assert_nil draft.owner_choice_note
    assert_equal receipt, draft.slice(*receipt.keys)
    assert_equal @preferred, series.keyword.reload.preferred_url
    assert_equal "open", action.reload.status
  end

  test "stale forms cannot attach a choice to newer evidence or a changed page setting" do
    series = enroll
    record_result(series, Time.current, 6)
    action = series.keyword_actions.find_by!(kind: "page_match")
    original = ActionDraft.current_for(action)
    action.update!(evidence: action.evidence.merge("winning_url" => "https://westbridge.example/new-result/"))
    current = ActionDraft.current_for(action)
    assert_not_equal original.id, current.id

    patch action_draft_choice_path(action), params: {draft_id: original.id, owner_choice: "keep_preferred"}
    assert_response :conflict
    series.keyword.update!(preferred_url: "https://westbridge.example/another-page/")
    patch action_draft_choice_path(action), params: {draft_id: current.id, owner_choice: "keep_preferred"}
    assert_response :conflict
    assert_nil original.reload.owner_choice
    assert_nil current.reload.owner_choice
  end

  test "invalid or overlong input cannot overwrite an existing choice and note" do
    series = enroll
    record_result(series, Time.current, 6)
    action = series.keyword_actions.find_by!(kind: "page_match")
    draft = ActionDraft.current_for(action)
    draft.update!(owner_choice: "keep_preferred", owner_choice_note: "Keep the existing page.")
    [{owner_choice: "unknown"}, {owner_choice: "prefer_ranking", owner_choice_note: "a" * 1001}].each do |input|
      patch action_draft_choice_path(action), params: input.merge(draft_id: draft.id)
      assert_response :unprocessable_entity
      assert_equal "keep_preferred", draft.reload.owner_choice
      assert_equal "Keep the existing page.", draft.owner_choice_note
    end
  end

  test "only site managers may save a choice and only for the selected site" do
    series = enroll
    record_result(series, Time.current, 6)
    action = series.keyword_actions.find_by!(kind: "page_match")
    draft = ActionDraft.current_for(action)
    params = {draft_id: draft.id, owner_choice: "keep_preferred"}
    @membership.update!(role: "viewer")
    patch action_draft_choice_path(action), params: params
    assert_response :forbidden
    @membership.update!(role: "owner")

    other_workspace = Workspace.create!(name: "Second workspace")
    other_site = other_workspace.sites.create!(name: "Second business", host: "second.example", location: "Leeds")
    other_workspace.memberships.create!(user: @membership.user, role: "owner")
    post select_site_path(other_site)
    patch action_draft_choice_path(action), params: params
    assert_response :not_found
    assert_nil draft.reload.owner_choice
  end

  test "only the current review can trigger a link check and a replay reuses the saved evidence" do
    series = enroll
    record_result(series, Time.current, 4)
    action = series.keyword_actions.find_by!(kind: "page_match")
    draft = ActionDraft.current_for(action)
    with_link_checker do |calls|
      get action_draft_path(action)
      assert_response :success
      assert_empty calls
      post action_draft_link_check_path(action), params: {draft_id: -1}
      assert_response :conflict
      assert_empty calls
      post action_draft_link_check_path(action), params: {draft_id: draft.id}
      assert_redirected_to action_draft_path(action, anchor: "link-check")
      assert_nil draft.reload.owner_choice
      assert_equal "contextual", draft.link_check_result.fetch("outcome")
      assert_equal 1, calls.size
      get action_draft_path(action)
      assert_response :success
      post action_draft_link_check_path(action), params: {draft_id: draft.id, recheck: "1"}
      assert_redirected_to action_draft_path(action, anchor: "link-check")
      assert_equal 1, calls.size
      travel 2.minutes do
        post action_draft_link_check_path(action), params: {draft_id: draft.id, recheck: "1"}
        assert_equal 2, calls.size
      end
      @membership.update!(role: "viewer")
      post action_draft_link_check_path(action), params: {draft_id: draft.id, recheck: "1"}
      assert_response :forbidden
      assert_equal 2, calls.size
      @membership.update!(role: "owner")
      other = @site.workspace.sites.create!(name: "Other", host: "other.example", location: "York")
      post select_site_path(other)
      post action_draft_link_check_path(action), params: {draft_id: draft.id}
      assert_response :not_found
      assert_equal 2, calls.size
    end
  end

  test "a preferred page change during a check discards the old result and releases its claim" do
    series = enroll
    record_result(series, Time.current, 4)
    action = series.keyword_actions.find_by!(kind: "page_match")
    draft = ActionDraft.current_for(action)
    with_link_checker(during: -> { series.keyword.update!(preferred_url: "https://westbridge.example/new-choice/") }) do
      post action_draft_link_check_path(action), params: {draft_id: draft.id}
      assert_response :conflict
      assert_empty draft.reload.link_check_result
      assert_nil draft.link_checked_at
      assert_nil draft.link_check_started_at
    end
  end

  test "an active link check coalesces requests and an expired claim can be retried" do
    series = enroll
    record_result(series, Time.current, 4)
    action = series.keyword_actions.find_by!(kind: "page_match")
    draft = ActionDraft.current_for(action)
    draft.update!(link_check_started_at: Time.current)
    with_link_checker do |calls|
      post action_draft_link_check_path(action), params: {draft_id: draft.id}
      assert_redirected_to action_draft_path(action, anchor: "link-check")
      assert_empty calls
      draft.update!(link_check_started_at: 4.minutes.ago)
      post action_draft_link_check_path(action), params: {draft_id: draft.id}
      assert_equal 1, calls.size
      assert_nil draft.reload.link_check_started_at
      assert_equal "contextual", draft.link_check_result.fetch("outcome")
    end
  end

  private

  def with_link_checker(during: nil)
    calls = []
    checker = Class.new do
      define_method(:initialize) { |**pages| calls << pages }
      define_method(:call) do
        during&.call
        {"outcome" => "contextual", "anchor" => "book a boiler service", "section" => "Booking", "placement" => "body",
          "source_url" => calls.last.fetch(:source_url), "target_url" => calls.last.fetch(:target_url), "target_status" => 200}
      end
    end
    stub_const(SiteAudits, :TargetedLinkCheck, checker) { yield calls }
  end

  def enroll
    Tracking::Enrollment.call(site: @site, phrase: @phrase, preferred_url: @preferred, devices: ["desktop"]).tracking_series.sole
  end

  def record_result(series, time, position)
    items = (1..position).map do |rank|
      { "type" => "organic", "rank_group" => rank, "url" => rank == position ? @winning : "https://result-#{rank}.example/" }
    end
    Tracking::ManualImport.call(series: series, payload: series.settings.merge("captured_at" => time.iso8601, "items" => items))
  end

  def handoff
    assert_select "textarea[data-action-handoff][readonly]", count: 1
    css_select("textarea[data-action-handoff]").first.text
  end
end
