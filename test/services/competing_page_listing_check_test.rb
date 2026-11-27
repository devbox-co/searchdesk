require "test_helper"

class CompetingPageListingCheckTest < ActiveSupport::TestCase
  setup do
    @site = Workspace.create!(name: "Owner").sites.create!(name: "Example Clinic", host: "clinic.example", location: "York,England,United Kingdom",
      tracking_mode: "manual", rank_country_code: "GB")
    @site.create_search_console_connection!(property: "sc-domain:clinic.example", status: "connected")
    keyword = @site.keywords.create!(phrase: "example clinic")
    @url = "https://clinic.example/"
    @other = "#{@url}guide/"
    data = {"query" => keyword.phrase, "country" => "GBR", "device" => "mobile", "property" => "sc-domain:clinic.example",
      "pages" => [@url, @other], "weeks" => [{"state" => "leader", "leader_url" => @url}]}
    @finding = SiteFinding.create!(site: @site, keyword: keyword, kind: "competing_pages", active: true, level: "watch", fingerprint: "a", evidence: data)
    @google = {"status" => "target_not_seen", "device" => "mobile", "coverage" => 28, "other_result" => {"url" => @other, "position" => 19, "title" => "Another page"}}
    @passage = "At Example Clinic in York you can meet a GP to discuss your skin concerns."
    @page = {"status" => "observed", "url" => @url, "title" => "Aesthetic Clinic | Example Clinic", "description" => "Premier Botox clinic in York.",
      "h1" => "Aesthetic clinic in York", "excerpts" => ["Get our newsletter and discounts for customers of Example Clinic in York.", @passage]}
  end

  def run_check(version: @finding.updated_at.iso8601(6), &during)
    google = ->(**) { during&.call; @google }
    page = ->(**) { @page }
    CompetingPages::ListingCheck.new(@finding, listing_reader: google, page_reader: page).run(version)
  end

  test "another page never supplies comparison wording; retain the exact title and propose a grounded description" do
    before = @finding.updated_at
    report = run_check
    assert_equal ["not_comparable", "not_comparable"], report["comparison"].values
    assert_equal [@page["title"], @passage, "proposed"], report["draft"].values_at("title", "description", "status")
    assert_includes report.dig("draft", "instructions"), @passage
    assert_includes report.dig("draft", "instructions"), "absent from the saved"
    assert_nil report.dig("page", "excerpts")
    assert_equal report, CompetingPages::ListingCheck.saved(@finding.reload)
    assert_equal before, @finding.updated_at
    @finding.update!(disposition: "monitor")
    assert_equal report, CompetingPages::ListingCheck.saved(@finding)
    @site.search_console_connection.update!(status: "reconnect")
    assert_nil CompetingPages::ListingCheck.saved(@finding.reload)
  end

  test "only compare each available field for the same observed page" do
    @google.merge!("status" => "observed", "url" => @url, "title" => @page["title"].gsub(" ", "  "), "description" => "Different…")
    assert_equal({"title" => "matches", "description" => "different"}, run_check["comparison"])
    @google["description"] = nil
    assert_equal "not_comparable", run_check.dig("comparison", "description")
    @page["url"] = @other
    assert_equal "unavailable", run_check.dig("draft", "status")
  end

  test "a clear description is retained even when Google uses different words" do
    @page["description"] = @passage
    @google.merge!("status" => "observed", "url" => @url, "title" => "Alternative")
    assert_equal "keep", run_check.dig("draft", "status")
    @page["field_states"] = {"description" => "multiple"}
    assert_equal "unavailable", run_check.dig("draft", "status")
  end

  test "requires a grounded usable passage for a suggested change" do
    @page["excerpts"] = ["Review the privacy policy for Example Clinic in York before checking your booking.",
      "Find out about bike locks and accessories on an afternoon visit to York."]
    assert_equal "unavailable", run_check.dig("draft", "status")
  end

  test "stale or competing work cannot replace the current review" do
    assert_raises(CompetingPages::ListingCheck::Stale) { run_check(version: "old") }
    @finding.update_columns(listing_check_token: "other", listing_check_started_at: Time.current)
    assert_raises(CompetingPages::ListingCheck::Busy) { run_check }
    assert_equal "other", @finding.reload.listing_check_token
    @finding.update_columns(listing_check_started_at: 3.minutes.ago)
    assert_raises(CompetingPages::ListingCheck::Stale) { run_check { @site.search_console_connection.update!(status: "reconnect") } }
    assert_nil @finding.reload.listing_check_token
    assert_nil @finding.listing_check
  end

  test "a third leading page cannot silently select a reviewed page" do
    evidence = @finding.evidence.deep_dup
    evidence["weeks"] << {"state" => "leader", "leader_url" => "#{@url}third/"}
    @finding.update!(evidence: evidence)
    assert_nil CompetingPages::ListingCheck.target_for(@finding)
  end
end
