require "test_helper"
require "active_support/testing/constant_stubbing"

class SeoPageComparisonTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::ConstantStubbing

  test "owners queue a same-service comparison and site members can read its scoped evidence" do
    user = User.create!(email: "comparison-owner@example.test", password: "long-comparison-password")
    workspace = Workspace.create!(name: "Comparison workspace")
    membership = workspace.memberships.create!(user: user, role: "owner")
    site = workspace.sites.create!(name: "Garden clinic", host: "garden.example", location: "Bath")
    other = Workspace.create!(name: "Another workspace").sites.create!(name: "Other clinic", host: "other.example", location: "York")
    post login_path, params: { session: { email: user.email, password: "long-comparison-password" } }

    route = compare_landing_pages_seo_workflows_path
    inputs = { own_page_url: "https://garden.example/consultations", competitor_page_url: "https://clinic.example/consultations" }
    get setup_seo_workflows_path
    assert_select '#E4 input[type=submit][value="Compare public pages"]'
    assert_no_difference -> { site.source_snapshots.count } do
      post route, params: inputs.merge(competitor_page_url: "https://clinic.example/consultations?token=no")
    end

    requests = []
    reader = Class.new do
      define_method(:get) do |uri, robots:|
        requests << [uri.host, uri.path]
        if robots
          body = uri.host == "clinic.example" ? "User-agent: *\nDisallow: /consultations\n" : "User-agent: *\n"
          SiteAudits::Fetcher::Response.new(200, nil, "text/plain", "", body)
        else
          body = <<~HTML
            <html><head><title>Consultations</title>
            <script type="application/ld+json">{"@type":"MedicalClinic","url":"https://garden.example/consultations"}</script>
            </head><body><main><h1>Consultation</h1><h2>What happens</h2>
            <p>Visit our clinic.</p><p hidden>Hidden source copy</p></main></body></html>
          HTML
          SiteAudits::Fetcher::Response.new(200, nil, "text/html", "", body)
        end
      end
    end

    stub_const(SiteAudits, :Fetcher, reader, exists: true) do
      reader.const_set(:AGENT, "SearchdeskBot/1.0")
      reader.const_set(:Response, Data.define(:status, :location, :content_type, :robots_header, :body))
      reader.const_set(:Error, Class.new(StandardError))
      assert_difference -> { site.source_snapshots.count }, 1 do
        perform_enqueued_jobs(only: SeoPageComparisonJob) { post route, params: inputs }
        post route, params: inputs
      end
    end
    assert_equal [["garden.example", "/robots.txt"], ["garden.example", "/consultations"], ["clinic.example", "/robots.txt"]], requests
    snapshot = site.source_snapshots.sole
    assert_equal "partial", snapshot.metrics.fetch("status")
    own = snapshot.metrics.fetch("pages").fetch("own")
    assert_equal 6, own.fetch("main_words")
    assert_equal true, own.fetch("storefront_markup")
    refute_includes snapshot.metrics.to_json, "Visit our clinic."

    membership.update!(role: "manager")
    post route, params: inputs
    assert_response :forbidden
    get evidence_preview_seo_workflows_path(template: "E4")
    assert_select "a[href=?]", source_snapshot_path(snapshot)
    get source_snapshot_path(snapshot)
    assert_select "p", text: "Only one page could be read."
    assert_select "p", text: /crawl rules prevent/
    foreign_record = other.source_snapshots.create!(snapshot.attributes.except("id", "site_id", "created_at", "updated_at"))
    get source_snapshot_path(foreign_record)
    assert_response :not_found
  end
end
