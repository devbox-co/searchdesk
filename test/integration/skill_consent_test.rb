require "test_helper"

class SkillConsentTest < ActionDispatch::IntegrationTest
  setup do
    workspace = Workspace.create!(name: "Consent test")
    @site = workspace.sites.create!(name: "Site", host: "consent.example", location: "Norwich")
    @owner = User.create!(email: "skill-owner@example.test", password: "local-password-for-tests")
    workspace.memberships.create!(user: @owner, role: "owner")
    post login_path, params: { session: { email: @owner.email, password: "local-password-for-tests" } }
  end

  test "repeat submission preserves consent revision and revocation clears wording and choice" do
    settings = { wording_setting: { enabled: "1", phrases: "Electrical repairs\nFuse board inspections" } }
    assert_difference("WordingRun.count", 1) { 2.times { patch wording_setting_path, params: settings } }
    setting = WordingSetting.find_by!(site: @site)
    run = setting.wording_runs.sole
    run.update!(status: "selected", choice: 1, attempted_at: Time.current)
    patch wording_setting_path, params: { wording_setting: {enabled: "0", phrases: "should be discarded"} }
    assert_redirected_to wording_setting_path
    assert_not setting.reload.enabled?
    assert_empty setting.phrases
    assert_nil setting.selected_line
    assert_equal "superseded", run.reload.status
    assert_nil run.choice
    assert run.attempted_at
  end

  test "duplicate draft posts reuse a dated receipt and old evidence is labelled" do
    keyword = Tracking::Enrollment.call(site: @site, phrase: "heating repair")
    item = keyword.tracking_series.first.keyword_actions.create!(kind: "page_match", title: "Compare pages",
      description: "Review the mismatch", observed_on: 3.days.ago.to_date, evidence: {"position" => 4})
    assert_no_difference("ActionDraft.count") { 2.times { post action_draft_path(item) } }
    assert_response :see_other
    follow_redirect!
    assert_select "p.notice", text: /more than a day old/
    assert_select "ol li", minimum: 1
    assert_select "details summary", text: "Review receipt"
  end

  test "manager cannot change consent and another site cannot read the preview" do
    @owner.memberships.sole.update!(role: "manager")
    patch wording_setting_path, params: {wording_setting: {enabled: "1", phrases: "Public text"}}
    assert_response :forbidden
    assert_nil WordingSetting.find_by(site: @site)
    other = Workspace.create!(name: "Another workspace").sites.create!(name: "Other", host: "other.example", location: "Bath")
    series = Tracking::Enrollment.call(site: other, phrase: "boiler service").tracking_series.first
    item = series.keyword_actions.create!(kind: "page_match", title: "Compare pages", description: "Other tenant",
      observed_on: Date.current, evidence: { "position" => 5 })
    get action_draft_path(item)
    assert_response :not_found
  end
end
