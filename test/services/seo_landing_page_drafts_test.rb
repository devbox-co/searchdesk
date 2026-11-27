require "test_helper"

class SeoLandingPageDraftsTest < ActiveSupport::TestCase
  test "existing schema reports field differences without proposing a duplicate entity" do
    host = "example.test"
    supplied = { "name" => "Public clinic", "telephone" => "+441632960010",
      "address" => { "streetAddress" => "1 Test Road", "addressCountry" => "GB" } }
    current = { "name" => " public clinic ", "telephone" => "+44 1632 960011",
      "address" => { "streetAddress" => "1 Test Road" } }
    brief = Struct.new(:id, :metrics).new(1, { "records" => [{ "page" => "/", "storefront" => supplied }] })
    page = { "path" => "/", "html" => true, "structured_markup_present" => true,
      "local_business_fingerprint" => SiteAudits::LocalBusinessMarkup.fingerprint(current, host) }

    result = SeoWorkflows::LandingPageDrafts.new(brief, "/site_audit", host: host).for_page(page).sole
    refute result.key?("draft")
    assert_includes result.fetch("text"), "Review mismatched fields: Telephone."
    assert_includes result.fetch("text"), "Fields missing from the observed entity: Address country."
    refute_includes result.fetch("text"), "960011"
  end
end
