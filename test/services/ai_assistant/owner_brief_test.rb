require "test_helper"

class AiAssistant::OwnerBriefTest < ActiveSupport::TestCase
  Snapshot = Data.define(:evidence, :answer)

  test "uses only selected facts and keeps their original measurements together" do
    rank = { "id" => "F1", "source" => "DataForSEO", "url" => "/rankings",
      "text" => "On 2026-11-25 in Example, Google organic tracking on desktop and mobile covered 42 keyword-device checks across 21 keywords. 19 numeric positions, 0 verified outside the top 30, 23 incomplete. 26 usable baselines. 3 unchanged, 10 down, 5 up. Incomplete checks reached 20–29 of the first 30 positions." }
    other = { "id" => "F2", "source" => "Project record", "text" => "Additional saved context." }
    unused = { "id" => "F3", "source" => "Project record", "text" => "Unselected observation." }
    report = Snapshot.new({ "facts" => [rank, other, unused] }, { "findings" => [
      { "fact_ids" => %w[F1 F2 missing F2], "text" => "Original evidence and check." }] })
    brief = AiAssistant::OwnerBrief.new(report)
    assert_equal [rank, other], brief.lead.facts
    assert_equal rank, brief.first_action.action_fact
    assert_not_includes brief.lead.meaning, "keyword-device"
    assert_not_equal rank["text"], brief.lead.meaning
  end

  test "preserves uncited older answers and avoids turning an unfamiliar measurement into an instruction" do
    original = "On 2026-01-01 a new measurement was recorded."
    report = Snapshot.new({}, { "findings" => [{ "text" => original }] })
    brief = AiAssistant::OwnerBrief.new(report)
    assert_equal original, brief.lead.original_text
    assert_not_includes brief.lead.meaning, "2026-01-01"
    assert_empty brief.lead.facts
    assert_nil brief.first_action
  end
end
