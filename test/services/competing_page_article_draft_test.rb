require "test_helper"

class CompetingPageArticleDraftTest < ActiveSupport::TestCase
  setup do
    @site = Site.new(name: "Example Clinic", location: "York, England", language: "en", rank_country_code: "GB")
    @home = "https://clinic.example/"
    @old = "#{@home}wrinkle-advice"
    @new = "#{@home}consultations"
    @google = {"title" => "Wrinkle treatment advice for patients ...", "url" => @old, "device" => "mobile"}
    @description = "Thinking about Botox? Read about a consultation in York, including aftercare and suitability."
    @dest = {"status" => "observed", "http_status" => 200, "url" => @new, "canonical" => @new,
      "title" => "Wrinkle consultations", "h1" => "Wrinkle consultations in York", "description" => @description,
      "headings" => ["What happens at a consultation?", "Aftercare"]}
    @page = {"url" => @old, "status" => "redirected", "destination" => @dest,
      "redirects" => [{"url" => @old, "location" => @new, "status" => 301}]}
    @link = {"outcome" => "source_redirected"}
  end

  def draft
    CompetingPages::ArticleDraft.call(site: @site, page: @page, google: @google, link: @link, homepage: @home)
  end

  test "keeps a relevant verified permanent redirect and labels optional copy only for its destination" do
    assert_equal "keep", draft["status"]
    assert_match(/no article body/i, draft["link_instruction"])
    assert_includes draft["instructions"], "#{@old} → HTTP 301 → #{@new}"
    edit = draft["edits"].sole
    assert_equal "Optional destination meta description", edit["label"]
    assert_equal @description, edit["before"]
    assert_equal "Read about a consultation in York, including aftercare and suitability.", edit["after"]
    assert_includes draft["instructions"], edit["after"]
    assert_includes draft["instructions"], "applies only to #{@new}"
    assert_equal CompetingPages::ListingDraft::ASA_GUIDANCE, draft["guidance_url"]
  end

  test "temporary, conflicting canonical and unrelated destinations require review" do
    @page["redirects"].first["status"] = 302
    assert_equal "review", draft["status"]
    @page["redirects"].first["status"] = 301
    @dest["canonical"] = @home
    assert_equal "review", draft["status"]
    @dest["canonical"] = @new
    @dest.merge!("title" => "Products and services in York", "h1" => "Example Clinic")
    assert_equal "review", draft["status"]
    assert_empty draft["edits"]
  end

  test "a redirect to the homepage cannot recommend an article link or homepage wording" do
    @page["redirects"].first["location"] = @home
    @dest.merge!("url" => @home, "canonical" => @home)
    assert_equal "review", draft["status"]
    assert_empty draft["edits"]
  end

  test "an optional destination edit requires safe remaining text and corroborating evidence" do
    @dest["headings"] = []
    assert_empty draft["edits"]
    @dest["headings"] = ["Consultation"]
    @dest["description"] = "Thinking about Botox? A consultation guarantees Botox."
    assert_empty draft["edits"]
    @dest["description"] = @description
    @site.rank_country_code = "US"
    assert_empty draft["edits"]
  end

  test "a readable article can retain its wording and gain one precisely placed homepage link" do
    paragraph = "Our team at Example Clinic explains what to bring to your first visit."
    @page = {"url" => @old, "status" => "observed", "title" => "Questions to ask at a first visit",
      "description" => "See what to bring when you meet the team.", "paragraphs" => [paragraph]}
    @link = {"outcome" => "navigation_only"}
    assert_match(/Add one homepage link/, draft["decision"])
    [paragraph, "About Example Clinic", @home].each { |text| assert_includes draft["link_instruction"], text }
    @link = {"outcome" => "contextual", "anchor" => "our clinic"}
    assert_equal "keep", draft["status"]
    assert_match(/Keep the existing article link “our clinic”/, draft["instructions"])
    @link = {"outcome" => "broken_target"}
    assert_match(/homepage returned an error/, draft["link_instruction"])
    assert_no_match(/add a link labelled/i, draft["link_instruction"])
  end

  test "a direct article receives an exact wording edit only when supported" do
    @page = {"url" => @old, "status" => "observed", "title" => nil, "h1" => "Consultation questions",
      "description" => "Questions for your first visit.", "paragraphs" => []}
    @link = {"outcome" => "missing"}
    assert_equal "Improve the article wording first.", draft["decision"]
    assert_equal "Consultation questions | Example Clinic", draft["edits"].sole["after"]
    assert_no_match(/add a link labelled/i, draft["link_instruction"])
  end

  test "a missing article description can use the verified article body" do
    passage = "A consultation at Example Clinic in York gives you time to discuss your concerns."
    @page = {"url" => @old, "status" => "observed", "title" => "Consultations | Example Clinic",
      "h1" => "A consultation at Example Clinic", "paragraphs" => [passage]}
    @link = {"outcome" => "contextual", "anchor" => "our clinic"}
    assert_equal "Article meta description", draft["edits"].sole["label"]
    assert_equal passage, draft["edits"].sole["after"]
  end

  test "an unreadable article never produces a public edit" do
    @page = {"url" => @old, "status" => "unavailable", "reason" => "The page could not be read."}
    assert_equal "review", draft["status"]
    assert_empty draft["edits"]
  end
end
