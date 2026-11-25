require "test_helper"

class AssistantPlaybooksTest < ActiveSupport::TestCase
  def fact(id, source, text)
    { "id" => id, "source" => source, "text" => text }
  end

  test "a daily brief uses reporting methods only for available observations" do
    weekly = fact("F1", "Weekly search clicks", "Four tracked searches had reported clicks on all fourteen days.")
    map = fact("F2", "Local Falcon", "Top three at 4 of 9 locations on the saved scan.")
    no_actions = fact("F3", "Keyword actions", "No currently open keyword actions with a reading through today.")
    disabled = fact("F4", "Source availability", "Sharing with the assistant is off for this site.")
    evidence = { "facts" => [weekly, map, no_actions, disabled] }

    payload = AiAssistant::OpenaiClient.prepare(kind: "brief", question: nil, evidence:)
    assert_equal %w[weekly_clicks maps], payload.playbook_keys
    instructions = JSON.parse(payload.json).fetch("instructions")
    assert_includes instructions, AiAssistant::Playbooks.find("maps").instruction
    assert_includes instructions, AiAssistant::Playbooks.find("weekly_clicks").instruction
    refute_includes instructions, AiAssistant::Playbooks.find("priority").instruction
    refute_includes instructions, map.fetch("text")

    question = AiAssistant::Playbooks.find("maps").question
    payload = AiAssistant::OpenaiClient.prepare(kind: "question", question:, evidence:)
    assert_equal ["maps"], payload.playbook_keys
  end

  test "the connection test has no site playbooks and unrecognised IDs have no handler" do
    payload = AiAssistant::OpenaiClient.prepare(kind: "test", question: nil, evidence: AiAssistant::Recipe.synthetic_evidence)
    assert_empty payload.playbook_keys
    assert_nil AiAssistant::Playbooks.find("arbitrary instruction")
    refute_includes JSON.parse(payload.json).fetch("instructions"), AiAssistant::Recipe::OWNER_REVIEW
  end
end
