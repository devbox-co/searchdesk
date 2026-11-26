require "test_helper"

class AiAssistant::BriefRankingReadingTest < ActiveSupport::TestCase
  def interpret(text, source = "DataForSEO")
    AiAssistant::BriefRankingReading.for({ "text" => text, "source" => source })
  end

  def coverage(movement, incomplete: 23)
    "On 2026-11-25 in Example,England,United Kingdom, Google organic tracking on desktop and mobile covered 42 keyword-device checks across 21 keywords. " \
      "19 numeric positions, 0 verified outside the top 30, #{incomplete} incomplete. 26 usable baselines. #{movement}. Incomplete checks reached 20–29 of the first 30 positions."
  end

  def rank(observation, baseline, end_text = "")
    "“local bakery” had a desktop Google organic check in Example,England on 2026-11-25 (#{observation}). #{baseline} #{end_text}".strip
  end

  test "the summary distinguishes comparable changes from incomplete checks" do
    result = interpret(coverage("3 unchanged, 10 down, 5 up"))
    assert_equal "More local rankings fell than rose", result[:headline]
    assert_includes result[:meaning], "10 checks were lower and 5 were higher"
    assert_includes result[:meaning], "More than half the checks were incomplete, so the overall picture is still uncertain."
    assert_includes interpret(coverage("3 unchanged, 10 down, 5 up", incomplete: 4))[:meaning], "4 of 42 checks were incomplete"
    assert_match(/next complete/, result[:action])
    assert_equal 40, result[:priority]
    assert_nil interpret(coverage("3 unchanged, 10 down, 5 up"), "Google Search Console")
  end

  test "tracks changes across the search cutoff without declaring unseen positions steady" do
    assert_match(/rose than fell/, interpret(coverage("2 entered, 1 left, 3 outside both"))[:headline])
    assert_match(/outside the tracked results/, interpret(coverage("3 outside both"))[:headline])
    assert_match(/held steady/, interpret(coverage("5 unchanged"))[:headline])
    assert_match(/too early/, interpret(coverage("Movement needs observations on two comparable dates"))[:headline])
    assert_nil interpret(coverage("8 unexplained movement"))
  end

  test "a measured drop and different ranking page point to a concrete first action" do
    result = interpret(rank("ranked at position 19", "The baseline on 2026-10-04 was position 2.",
      "Down 17 places since baseline. Winning page /news/article/. Preferred page /."))
    assert_equal "“local bakery” fell on desktop", result[:headline]
    assert_match(/2nd to 19th since tracking began/, result[:meaning])
    assert_match(/different page/, result[:meaning])
    assert_match(/Compare the page Google showed for “local bakery”/, result[:action])
    assert_equal 10, result[:priority]
    refute_match(/2026-|article|baseline|yesterday/, result.values.join(" "))
  end

  test "the first, incomplete, outside and simulated readings have different meanings" do
    first = interpret(rank("ranked at position 5", "The baseline on 2026-11-25 was position 5."))
    assert_match(/starting point/, first[:meaning])
    missing = interpret(rank("incomplete coverage through 20, without an exact rank", "The baseline on 2026-11-24 was position 3."))
    assert_match(/still unknown/, missing[:headline])
    outside = interpret(rank("verified outside the top 30", "No usable baseline."))
    assert_match(/outside the top 30/, outside[:headline])
    demo = interpret(rank("ranked at position 3", "The baseline on 2026-11-01 was position 8."), "Simulated demonstration")
    assert_match(/Demo/, demo[:headline])
    assert_match(/demo/, demo[:action])
  end

  test "open actions can describe recurring rank drops or pages to review" do
    page = interpret("“local bakery” has preferred-page checks on desktop on 2026-11-24, mobile on 2026-11-25. Check the pages.", "Keyword actions")
    assert_match(/desktop and mobile/, page[:meaning])
    assert_match(/Compare the two pages/, page[:action])
    drop = interpret("“local bakery” has checks for sustained rank drops on mobile on 2026-11-25. Review the page.", "Keyword actions")
    assert_equal 20, drop[:priority]
    assert_match(/consecutive/, drop[:meaning])
    assert_nil interpret("No currently open keyword actions with a reading through 2026-11-25.", "Keyword actions")
    assert_nil interpret("An unfamiliar format.")
  end
end
