require "test_helper"
require "active_support/testing/constant_stubbing"

class ProspectAuditsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::ConstantStubbing

  setup do
    @user = User.create!(email: "p1-owner@example.test", password: "long-prospect-fixture-password")
    @workspace = Workspace.create!(name: "Prospect workspace")
    @membership = @workspace.memberships.create!(user: @user, role: "owner")
    @site = @workspace.sites.create!(name: "Agency", host: "agency.example", location: "Bath")
    post login_path, params: { session: { email: @user.email, password: "long-prospect-fixture-password" } }
    @target = { business_name: "Garden Studio", target_host: "www.garden.example", market: "Bath, England",
      keyword: "garden design" }
  end

  test "owner starts P1 from the task list and sees scoped observations after a capped crawl" do
    get seo_workflows_path
    assert_select "a[href=?]", prospect_audits_path, text: "Live prospect audits"
    get new_prospect_audit_path
    assert_select "form[action=?] input[type=submit]", prospect_audits_path, count: 1
    with_site_fixture do |requests|
      perform_enqueued_jobs(only: ProspectAuditJob) do
        post prospect_audits_path, params: { prospect_audit: @target }
      end
      assert_equal ["/robots.txt", "/", "/a", "/b", "/c", "/d"], requests
    end
    audit = @site.prospect_audits.sole
    assert_redirected_to prospect_audit_path(audit)
    assert_equal "complete", audit.website_status
    assert_equal "off", audit.provider_status
    refute_includes audit.website_report.to_json, "Discarded body fixture"
    follow_redirect!
    assert_select "h1", text: "Garden Studio"
    assert_select "p", text: /URLs checked: 5 · HTML pages: 5/
    assert_select "li", text: /Missing main heading/
    assert_equal "no-store", response.headers["Cache-Control"]

    assert_no_enqueued_jobs do
      post prospect_audits_path, params: { prospect_audit: @target }
    end
    assert_redirected_to prospect_audit_path(audit)

    @membership.update!(role: "manager")
    get prospect_audit_path(audit)
    assert_response :forbidden
    @membership.update!(role: "owner")
    other = Workspace.create!(name: "Unrelated workspace")
    foreign = other.sites.create!(name: "Unrelated agency", host: @site.host, location: "Bath").prospect_audits.create!(
      site_host: @site.host, requested_by: @user, requested_on: Date.current, **@target)
    get prospect_audit_path(foreign)
    assert_response :not_found
  end

  test "invalid targets and disabled provider collection are rejected before scheduling" do
    assert_no_enqueued_jobs do
      post prospect_audits_path, params: { prospect_audit: @target.merge(target_host: "http://127.0.0.1/private") }
      assert_response :unprocessable_entity
      post prospect_audits_path, params: { prospect_audit: @target.merge(provider: "1") }
      assert_response :unprocessable_entity
    end
    assert_equal 0, @site.prospect_audits.count
  end

  test "optional provider follows asynchronous submit and poll, reserves one paid attempt and discards unverified narrative" do
    env = { "LOCALSEODATA_API_KEY" => "sk_test_fixture", "LOCALSEODATA_SITE_ID" => @site.id.to_s,
      "LOCALSEODATA_SITE_HOST" => @site.host, "LOCALSEODATA_ALLOWED_TASKS" => "P1" }
    saved = env.keys.to_h { |key| [key, ENV[key]] }
    env.each { |key, value| ENV[key] = value }
    get new_prospect_audit_path
    assert_select "#prospect_audit_provider"
    with_site_fixture do
      perform_enqueued_jobs(only: ProspectAuditJob) { post prospect_audits_path, params: { prospect_audit: @target.merge(provider: "1") } }
    end
    audit = @site.prospect_audits.sole
    requests = []
    transport = Class.new(Net::HTTP) do
      define_method(:start) { |&block| block.call(self) }
      define_method(:request) do |req, &receive|
        requests << [address, req.method, req.path, req.body && JSON.parse(req.body)]
        data = if req.method == "POST"
          { job_id: "audit_fixture", status: "pending", poll_url: "https://outside.example/ignore-this" }
        else
          { job_id: "audit_fixture", status: "complete", rating: 4.8, local_pack_position: nil,
            competitors: [{ name: "Bath Landscapes", rank: 2, reviews_count: 99 }],
            organic_positions: [{ keyword: "gardens near Bath", rank: 12 }],
            recommendations: ["Unverified revenue estimate"] }
        end
        reply = Net::HTTPOK.new("1.1", "200", "OK")
        reply.define_singleton_method(:read_body) { |&block| block.call(JSON.generate(status: "success", data: data)) }
        receive.call(reply)
      end
    end

    stub_const(Net, :HTTP, transport) do
      2.times { ProspectAuditProviderJob.perform_now(audit.id) }
      assert_equal "pending", audit.reload.provider_status
      audit.update!(next_poll_at: 1.second.ago)
      ProspectAuditProviderJob.perform_now(audit.id)
    end
    assert_equal [
      ["api.localseodata.com", "POST", "/v1/audit/local", { "business_name" => "Garden Studio", "location" => "Bath, England" }],
      ["api.localseodata.com", "GET", "/v1/audit/local/status/audit_fixture", nil]
    ], requests
    get prospect_audit_path(audit)
    assert_select "li", text: /Bath Landscapes.*Position 2/m
    assert_select "li", text: /gardens near Bath.*Position 12/
    assert_select "dd", text: "Not reported", minimum: 1
    refute_includes response.body, "Unverified revenue estimate"

    post prospect_audits_path, params: { prospect_audit: @target.merge(business_name: "Different studio", provider: "1") }
    assert_response :unprocessable_entity
    assert_equal 1, @site.prospect_audits.count
  ensure
    saved&.each { |key, value| ENV[key] = value }
  end

  private

  def with_site_fixture
    calls = []
    fetcher = Object.new
    fetcher.define_singleton_method(:get) do |uri, robots: false|
      calls << uri.path
      body = if robots
        "User-agent: *\nAllow: /"
      elsif uri.path == "/"
        '<p>Discarded body fixture</p>' + %w[a b c d e f].map { |slug| %(<a href="/#{slug}">Link</a>) }.join
      else
        "<title>A page</title><h1>A page</h1>"
      end
      SiteAudits::Fetcher::Response.new(200, nil, "text/html", "", body)
    end

    factory = Class.new(SiteAudits::Crawler) do
      define_method(:initialize) { |**kwargs| super(**kwargs, fetcher: fetcher, sleeper: ->(_) {}) }
    end
    stub_const(SiteAudits, :Crawler, factory) { yield calls }
  end
end
