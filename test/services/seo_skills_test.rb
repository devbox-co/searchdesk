require "test_helper"

class SeoSkillsTest < ActiveSupport::TestCase
  setup do
    workspace = Workspace.create!(name: "Skill tests")
    @site = workspace.sites.create!(name: "Skill site", host: "skills.example", location: "Norwich")
    @setting = WordingSetting.create!(site: @site, enabled: true, phrases: "Boiler repairs\nHeating maintenance")
    @calls = []
    calls = @calls
    @fake = Object.new
    @fake.define_singleton_method(:choose) do |lines, model:|
      calls << [lines, model]
      2
    end
    fake = @fake
    @job = WordingJob.new
    @job.define_singleton_method(:wording_client) { fake }
    @old_key = ENV["ANTHROPIC_API_KEY"]
    @old_model = ENV["SEO_AI_MODEL"]
    ENV["ANTHROPIC_API_KEY"] = "unit-test-only"
    ENV["SEO_AI_MODEL"] = "offline-test"
  end

  teardown do
    ENV["ANTHROPIC_API_KEY"] = @old_key
    ENV["SEO_AI_MODEL"] = @old_model
  end

  test "only known versioned handlers and matching steps can run" do
    assert_equal SeoSkills::ActionReview, SeoSkills::Registry.fetch("action_review")[:handler]
    assert_equal SeoSkills::WordingClient, SeoSkills::Registry.fetch("business_wording")[:handler]
    assert_raises(KeyError) { SeoSkills::Registry.fetch("../../secret") }
    assert_nil SeoSkills::ActionReview.for("unapproved").last
  end

  test "local receipts preserve relevant dated evidence and are idempotent" do
    keyword = Tracking::Enrollment.call(site: @site, phrase: "boiler service")
    series = keyword.tracking_series.find_by!(device: "mobile")
    facts = { "position" => 12, "observation_id" => 4, "source" => "manual", "unused" => "ignore" }
    item = series.keyword_actions.create!(kind: "page_match", observed_on: Date.current,
      title: "Match the page", description: "Compare pages", evidence: facts)
    first = item.action_drafts.sole
    assert_equal "action_review/v1", first.skill_version
    assert_equal ["observation_id", "position", "source"], first.input_snapshot["evidence"].keys.sort
    assert_equal "Norwich", first.input_snapshot.fetch("location")
    assert_equal first, ActionDraft.capture!(item)
    assert_equal first, ActionDraft.current_for(item)
    item.update!(evidence: facts.merge("position" => 9), observed_on: Date.current.tomorrow)
    assert_equal 2, item.action_drafts.count
    assert_not_equal first.input_digest, ActionDraft.current_for(item).input_digest
    assert_equal 12, first.reload.input_snapshot.dig("evidence", "position")
    assert_empty @calls
  end

  test "public phrase validation rejects links contact details markup duplicates and oversized inputs" do
    invalid = ["https://private.example", "Use example.org", "Ask joe@example.org", "Call +44 (0123) 456789",
      "Text <mark>services</mark>", "Same line\nSame line", "x" * 161, (1..7).map { |i| "Service #{i}" }.join("\n")]
    invalid.each do |phrase|
      @setting.phrases = phrase
      assert_not @setting.valid?, phrase
    end
    @setting.phrases = "  Heating repairs \n\n 24-hour emergency plumbing  "
    assert @setting.valid?
    assert_equal ["Heating repairs", "24-hour emergency plumbing"], @setting.lines
  end

  test "absent provider configuration never dispatches a model call" do
    ENV.delete("ANTHROPIC_API_KEY")
    run = new_revision
    @job.perform(run.id)
    assert_equal "template", run.reload.status
    assert_nil run.attempted_at
    assert_empty @calls
  end

  test "one model call per revision returns only an approved line" do
    run = new_revision
    2.times { @job.perform(run.id) }
    assert_equal [[["Boiler repairs", "Heating maintenance"], "offline-test"]], @calls
    assert_equal "selected", run.reload.status
    assert_equal "Heating maintenance", @setting.reload.selected_line
  end

  test "attempt is charged once even on timeout or a lost worker" do
    calls = @calls
    @fake.define_singleton_method(:choose) do |lines, model:|
      calls << lines
      raise SeoSkills::WordingClient::Unavailable
    end
    run = new_revision
    2.times { @job.perform(run.id) }
    assert_equal 1, @calls.length
    assert_equal "template", run.reload.status
    assert run.attempted_at
    lost = new_revision
    lost.update!(status: "running", attempted_at: 11.minutes.ago)
    WordingRecoveryJob.new.perform
    @job.perform(lost.id)
    assert_equal "template", lost.reload.status
    assert_equal 1, @calls.length
  end

  test "UTC day cap includes failed and superseded attempts and resets at midnight" do
    travel_to Time.utc(2026, 11, 18, 23, 59) do
      3.times do
        run = new_revision
        @job.perform(run.id)
        run.update!(status: "superseded", choice: nil)
      end
      denied = new_revision
      @job.perform(denied.id)
      assert_equal "daily_limit", denied.reload.status
      assert_nil denied.attempted_at
    end
    travel_to Time.utc(2026, 11, 19, 0, 1) do
      @job.perform(new_revision.id)
      assert_equal 4, @calls.length
    end
  end

  test "old or revoked approval cannot issue a request" do
    old = new_revision
    old.update_column(:created_at, 25.hours.ago)
    @job.perform(old.id)
    assert_equal "expired", old.reload.status
    revoked = new_revision
    @setting.update!(enabled: false, phrases: "", revision: SecureRandom.uuid)
    @job.perform(revoked.id)
    assert_equal "superseded", revoked.reload.status
    assert_nil @setting.selected_line
    assert_empty @calls
  end

  test "revocation after durable reservation prevents provider dispatch" do
    @job.define_singleton_method(:reserve_attempt) do |setting, run|
      reserved = super(setting, run)
      setting.update!(enabled: false, phrases: "", revision: SecureRandom.uuid)
      run.update!(status: "superseded")
      reserved
    end
    run = new_revision
    @job.perform(run.id)
    assert_equal "superseded", run.reload.status
    assert run.attempted_at
    assert_empty @calls
  end

  test "a queued revision cannot run under a different recipe" do
    run = new_revision
    run.update!(skill_version: "retired/v0")
    @job.perform(run.id)
    assert_equal "template", run.reload.status
    assert_nil run.attempted_at
    assert_empty @calls
  end

  test "only a bounded integer in the exact response schema is accepted" do
    make_response = ->(choice) { { stop_reason: "end_turn", content: [{type: "text", text: JSON.generate(choice)}] }.to_json }
    assert_equal 2, SeoSkills::WordingClient.parse(make_response.call({choice: 2}), 2)
    [{choice: 0}, {choice: 3}, {choice: "1"}, {choice: 1, extra: "generated text"}, ["two"]].each do |invalid|
      assert_raises(SeoSkills::WordingClient::Unavailable) { SeoSkills::WordingClient.parse(make_response.call(invalid), 2) }
    end
    assert_raises(SeoSkills::WordingClient::Unavailable) { SeoSkills::WordingClient.parse('{"content":[]}', 2) }
  end

  private

  def new_revision
    @setting.update!(revision: SecureRandom.uuid)
    @setting.wording_runs.create!(revision: @setting.revision)
  end
end
