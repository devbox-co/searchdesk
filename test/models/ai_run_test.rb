require "test_helper"

class AiRunTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(email: "ai-models@example.test", password: "correct-test-password")
    @workspace = Workspace.create!(name: "Models test")
    @workspace.memberships.create!(user: @owner, role: "owner")
    @site = @workspace.sites.create!(name: "Clinic", host: "clinic.example", location: "London")
    @connection = AiConnection.create!(workspace: @workspace, api_key: "sk-proj-testmodels", monthly_budget_cents: 100)
    @connection.update!(status: "ready")
    @setting = AiSetting.create!(site: @site, enabled: true, daily_brief_enabled: true)
  end

  def ask(key: SecureRandom.uuid, question: "How are our rankings?", parent: nil)
    AiRun.request!(site: @site, user: @owner, kind: "question", question: question, request_key: key, parent: parent)
  end

  test "encrypted keys rotate independently of billing and invalidate pending requests" do
    row = AiConnection.connection.select_value("SELECT api_key FROM ai_connections WHERE id = #{@connection.id.to_i}")
    assert_not_includes row, "sk-proj-testmodels"
    assert_not_includes @connection.inspect, "sk-proj-testmodels"
    pending = ask
    original = @connection.revision
    @connection.update!(monthly_budget_cents: 50)
    assert_equal original, @connection.revision
    @connection.update!(api_key: "sk-proj-replacement")
    assert_not_equal original, @connection.revision
    assert_equal "untested", @connection.status
    assert_not pending.authorized_for_dispatch?(connection: @connection, setting: @setting)
    assert_not @connection.update(api_key: "sk-admin-invalid")
    assert_not_includes @connection.errors.full_messages.to_sentence, "sk-admin-invalid"
  end

  test "duplicate form submissions reuse one request and cannot replace its content" do
    first = ask(key: "form")
    assert_equal first, ask(key: "form")
    assert_raises(ActiveRecord::RecordInvalid) { ask(key: "form", question: "Other question") }
    assert_equal 1, @site.ai_runs.count
    assert_raises(ActiveRecord::RecordInvalid) { ask(question: "test sk-proj-nevertransmit123") }
  end

  test "erasing a conversation removes descendants and preserves the receipt across a disconnect" do
    parent = ask
    parent.update!(status: "complete", attempted_at: Time.current, actual_microusd: 123, reserved_microusd: 900)
    child = ask(parent: parent)
    assert child.visible_to?(user: @owner)
    parent.erase_content!
    [parent, child.reload].each do |run|
      assert run.erased_at
      assert_nil run.question
      assert_empty run.answer
      assert_empty run.evidence
      assert_not run.visible_to?(user: @owner)
    end
    @connection.disconnect!
    assert_equal 123, @connection.month_spend_microusd
    assert_not @setting.reload.daily_brief_enabled?
    assert_not @connection.reload.configured?
  end

  test "private questions and site-specific permissions cannot cross a membership boundary" do
    outsider = User.create!(email: "ai-outsider@example.test", password: "correct-test-password")
    other = Workspace.create!(name: "Second workspace")
    other.memberships.create!(user: outsider, role: "owner")
    run = ask
    assert_not run.visible_to?(user: outsider)
    assert_raises(ActiveRecord::RecordInvalid) { AiRun.request!(site: @site, user: outsider, kind: "question", question: "hello") }
    @workspace.memberships.create!(user: outsider, role: "manager")
    @setting.update!(managers_enabled: true)
    assert_not run.visible_to?(user: outsider)
    delegated = AiRun.request!(site: @site, user: outsider, kind: "question", question: "What changed?")
    @setting.update!(managers_enabled: false)
    assert_not delegated.visible_to?(user: outsider)
    assert_not delegated.authorized_for_dispatch?(connection: @connection, setting: @setting)
  end

  test "revoked references immediately hide answers and cleanup removes saved content" do
    run = ask
    evidence = AiAssistant::Evidence.build(site: @site, setting: @setting, day: Date.current, kind: "question", question: run.question)
    evidence["access"]["records"]["snapshots"] = [-98765]
    run.update!(evidence: evidence, answer: {"findings" => [{"text" => "restricted", "fact_ids" => ["F1"]}]}, status: "complete")
    assert_not run.visible_to?(user: @owner)
    AiEvidenceCleanupJob.perform_now
    assert_empty run.reload.answer
    assert run.erased_at
  end
end
