require "test_helper"
require "active_support/testing/constant_stubbing"

class SeoLiveProvidersTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::ConstantStubbing
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(email: "provider-owner@example.test", password: "long-provider-test-password")
    @workspace = Workspace.create!(name: "Provider workflow workspace")
    @membership = @workspace.memberships.create!(role: "owner", user: @user)
    @site = @workspace.sites.create!(name: "Fictional heating", host: "heating.example", location: "Bath")
    post login_path, params: { session: { email: @user.email, password: "long-provider-test-password" } }
    assert_redirected_to dashboard_path
    @requests = []
  end

  test "Slack follows the notification job once and cancels a replaced destination" do
    travel_to Time.utc(2026, 6, 1, 10) do
      webhook = "https://hooks.slack.com/services/TFIXTURE/BFIXTURE/syntheticWebhookKey"
      patch slack_seo_workflows_path, params: { webhook: "https://hooks.slack.com.example.test/services/TFIXTURE/BFIXTURE/syntheticWebhookKey" }
      assert_response :unprocessable_entity
      patch slack_seo_workflows_path, params: { webhook: webhook }
      assert_redirected_to seo_workflows_path
      assert_equal webhook, @site.reload.seo_slack_webhook
      get seo_workflows_path
      refute_includes response.body, "syntheticWebhookKey"

      prepare_crawl
      post run_seo_workflows_path, params: { template: "R2" }
      with_http do |host, method, path, body|
        assert_equal ["hooks.slack.com", "POST"], [host, method]
        assert_match(%r{\A/services/TFIXTURE/BFIXTURE/}, path)
        assert_match(/Review requested.*seo_workflows/m, body.fetch("text"))
        refute_match(/Fictional heating|Website crawl/, body.fetch("text"))
        [200, "ok"]
      end
      assert_equal 1, @requests.size
      assert_equal "sent", SeoWorkflowNotification.find_by!(kind: "awaiting_approval").slack_status

      post run_seo_workflows_path, params: { template: "R1" }
      patch slack_seo_workflows_path, params: { webhook: "" }
      SeoWorkflowNotificationsJob.perform_now
      assert_equal "cancelled", SeoWorkflowNotification.find_by!(kind: "complete").slack_status
    end
  end

  test "Google OAuth, bound live reads and exact owner approved post and reply traverse the real client" do
    use_google_environment do
      travel_to Time.utc(2026, 6, 1, 10) do
        with_http(run_job: false) do |host, method, path, body|
          google_response(host, method, path, body)
        end

        connection = @site.reload.business_profile_connection
        assert_equal "101", connection.account_id
        assert_equal "202", connection.location_id
        assert_equal "test-google-refresh", connection.refresh_token
        assert_equal 1, @requests.count { |row| row[1] == "POST" && row[2].end_with?("/localPosts") }
        assert_equal 1, @requests.count { |row| row[1] == "PUT" && row[2].end_with?("/reviews/fixture-review/reply") }
        assert_equal 2, BusinessProfilePublication.where(status: "published").count
      end
    end
  end

  test "M4 and M5 read provider features from the normal scoped rank capture" do
    travel_to Time.utc(2026, 5, 31, 12) do
      @site.update!(tracking_mode: "dataforseo", rank_location_verified_at: Time.current,
        rank_location_name: "Bath", rank_location_code: 123, rank_country_code: "GB")
      @site.create_local_falcon_connection!(place_id: "ChIJverified", verified_name: "Fictional heating",
        synced_at: Time.current)
      series = Tracking::Enrollment.call(site: @site, phrase: "heating repair", devices: ["desktop"]).tracking_series.sole
      organic = { "type" => "organic", "rank_group" => 1, "url" => "https://heating.example/service" }
      overview = { "type" => "ai_overview", "page" => 1, "items" => [
        { "type" => "ai_overview_element", "references" => [{ "url" => "https://heating.example/guidance" }] }
      ] }
      panel = { "type" => "local_services", "page" => 1, "items" => [
        { "type" => "local_services_element", "url" => "https://www.google.com/search?sabplaceid=ChIJother" },
        { "type" => "local_services_element", "url" => "https://www.google.com/search?sabplaceid=ChIJverified" }
      ] }
      observation = Tracking::RecordResult.call(series: series, captured_at: Time.current, items: [organic, overview, panel])
      assert_equal 2, observation.evidence.dig(Tracking::GoogleLocalServices::KEY, "panel_position")
      assert_equal true, observation.evidence.dig(Tracking::GoogleAiOverview::KEY, "site_link_observed")
      refute_includes observation.evidence.to_json, "guidance"
    end
    travel_to Time.utc(2026, 6, 1, 10) do
      post run_seo_workflows_path, params: { template: "M5" }
      follow_redirect!
      assert_select "li", text: /1 of 1 supplied overview payloads linked to this site/
      post run_seo_workflows_path, params: { template: "M4" }
      follow_redirect!
      assert_select "li", text: /Matched listing at position 2 in the first Local Services panel/
    end
  end

  test "M4 recovers DataForSEO panels and compares verified positions across adjacent weeks" do
    env = { "DATAFORSEO_ENABLED" => "true", "DATAFORSEO_LOGIN" => "fixture", "DATAFORSEO_PASSWORD" => "fixture",
      "DATAFORSEO_ALLOWED_SERIES_IDS" => nil }
    dates = [Time.utc(2026, 6, 1, 10), Time.utc(2026, 6, 8, 10)]
    wanted = "https://www.google.com/localservices/profile?sabplaceid=ChIJfixturePlace"
    another = "https://www.google.co.uk/localservices/profile?sabplaceid=ChIJanother"
    receipts = {}
    dates.each_with_index do |time, index|
      travel_to time do
        if index.zero?
          enable_competitor_tracking
          @site.create_local_falcon_connection!(place_id: "ChIJfixturePlace", verified_name: "Fictional heating", synced_at: time)
        end
        id = format("06051709-1535-0298-0000-%012d", index + 1)
        organic = { "type" => "organic", "rank_group" => 1, "url" => "https://heating.example/service" }
        observation = Tracking::RecordResult.call(series: @competitor_series, captured_at: time, reference: id, items: [organic])
        assert_equal "no_panel", observation.evidence.dig(Tracking::GoogleLocalServices::KEY, "coverage")
        observation.update!(evidence: observation.evidence.except(Tracking::GoogleLocalServices::KEY))
        observation.daily_slot.update!(attempted_at: time, task_id: id, attempt_key: "lsa-receipt-#{index}")
        urls = index.zero? ? [another, wanted] : [another, another, another, another, wanted]
        panel = { "type" => "local_services", "page" => 1,
          "items" => urls.map { |url| { "type" => "local_services_element", "url" => url, "phone" => "unstored fixture" } } }
        receipts[id] = [observation, [organic, panel]]
      end
    end

    with_environment(env) do
      travel_to Time.utc(2026, 6, 8, 12) do
        route = recover_local_services_evidence_seo_workflows_path
        get setup_seo_workflows_path
        assert_select "#M4 form[action=?] select option", route, text: /heating repair.*desktop/
        @membership.update!(role: "viewer")
        post route, params: { series_id: @competitor_series.id }
        assert_response :forbidden
        @membership.update!(role: "owner")

        settings = @competitor_series.settings
        responder = lambda do |host, method, path, _|
          assert_equal ["api.dataforseo.com", "GET"], [host, method]
          id = path.split("/").last
          assert_equal "/v3/serp/google/organic/task_get/advanced/#{id}", path
          observation, items = receipts.fetch(id)
          data = { device: settings.fetch("device"), os: settings.fetch("os"), se: "google", se_type: "organic",
            tag: observation.daily_slot.attempt_key }
          result = { keyword: settings.fetch("keyword"), location_code: settings.fetch("location_code"),
            language_code: settings.fetch("language"), datetime: observation.captured_at.utc.iso8601, items: items }
          [200, { status_code: 20000, tasks: [{ id: id, status_code: 20000, data: data, result: [result] }] }]
        end

        stub_provider_http(responder) do
          2.times do
            perform_enqueued_jobs(only: SeoLocalServicesEvidenceJob) { post route, params: { series_id: @competitor_series.id } }
            assert_redirected_to setup_seo_workflows_path(anchor: "M4")
          end
        end
        assert_equal 2, @requests.size
        source = receipts.values.last.first.reload
        refute_includes source.evidence.to_json, "unstored fixture"
        get evidence_preview_seo_workflows_path(template: "M4")
        assert_select "li", text: /Matched listing at position 5.*Previous sample on 2026-06-01: position 2.*moved outside/
        assert_select "a[href=?]", local_services_capture_seo_workflows_path(capture_id: receipts.values.first.first.id),
          text: "View comparison sample"
        get local_services_capture_seo_workflows_path(capture_id: source)
        assert_select "p", text: /Ads returned in the first panel.*5/
        refute_includes response.body, wanted
      end

      travel_to Time.utc(2026, 6, 9, 10) do
        save_competitor_pack([])
        get evidence_preview_seo_workflows_path(template: "M4")
        assert_select "li", text: /No Local Services Ads panel was returned/
        refute_includes response.body, "The listing moved outside"
        assert_select "a", text: "View comparison sample", count: 0
      end
    end
  end

  test "paid AI samples require a scoped owner, reserve once and display provider citation coverage" do
    values = {
      "DATAFORSEO_ENABLED" => "true", "DATAFORSEO_LOGIN" => "fixture", "DATAFORSEO_PASSWORD" => "fixture",
      "DATAFORSEO_AI_SITE_ID" => @site.id.to_s, "DATAFORSEO_AI_SITE_HOST" => @site.host
    }
    with_environment(values) do
      travel_to Time.utc(2026, 5, 31, 12) do
        args = { site: @site, owner_id: @user.id, country: "GB", engine: "gemini", prompt: "Where can I find a boiler installer in Bath?" }
        service = SeoWorkflows::AiVisibilitySample
        viewer = User.create!(email: "sample-viewer@example.test", password: "long-viewer-test-password")
        @workspace.memberships.create!(user: viewer, role: "viewer")
        assert_raises(SeoWorkflows::AiVisibilitySample::Unavailable) { service.call(**args.merge(owner_id: viewer.id)) }
        other = @workspace.sites.create!(name: "Other", host: "other.example", location: "Bath")
        assert_raises(SeoWorkflows::AiVisibilitySample::Unavailable) { service.call(**args.merge(site: other)) }
        responder = lambda do |host, method, path, body|
          engine = path.split("/").fetch(3)
          assert_equal ["api.dataforseo.com", "POST"], [host, method]
          fields = body.sole
          assert_equal "Market: GB. #{args[:prompt]}", fields.fetch("user_prompt")
          if engine == "gemini"
            assert_equal true, fields.fetch("web_search")
            annotations = [{ "url" => "https://redirect.example/1", "direct_url" => "https://www.heating.example/private-path" }]
          else
            assert_equal "GB", fields.fetch("web_search_country_iso_code")
            annotations = []
          end
          [200, { status_code: 20000, tasks: [{ id: "09041216-1444-0612-0000-7eaf4493f783",
            status_code: 20000, data: fields.merge("se" => engine),
            result: [{ model_name: fields.fetch("model_name"), web_search: true, items: [
              { type: "message", sections: [{ type: "text", text: "unstored generated answer", annotations: annotations }] }
            ] }] }] }]
        end
        stub_provider_http(responder) do
          gemini = service.call(**args)
          assert_equal true, gemini.metrics.fetch("site_cited")
          refute_match(/private-path|unstored generated answer|boiler installer/, gemini.metrics.to_json)
          assert_raises(SeoWorkflows::AiVisibilitySample::Unavailable) { service.call(**args) }
          perplexity = service.call(**args.merge(engine: "perplexity"))
          assert_nil perplexity.metrics.fetch("site_cited")
        end
        assert_equal 2, @requests.size
      end
    end

    travel_to Time.utc(2026, 6, 1, 10) do
      post run_seo_workflows_path, params: { template: "M5" }
      follow_redirect!
      assert_select "li", text: /Gemini response sample.*Site link observed: yes/m
      assert_select "li", text: /Perplexity response sample.*No usable citation URLs returned/m
    end
  end

  test "M5 owners can queue an exact ChatGPT sample and view its citations before the monthly report" do
    prompt = "Where can I find a boiler installer in Bath?"
    values = {
      "DATAFORSEO_ENABLED" => "true", "DATAFORSEO_LOGIN" => "fixture", "DATAFORSEO_PASSWORD" => "fixture",
      "DATAFORSEO_AI_SITE_ID" => @site.id.to_s, "DATAFORSEO_AI_SITE_HOST" => @site.host,
      "DATAFORSEO_AI_WEB_COUNTRY" => "GB", "DATAFORSEO_AI_WEB_PROMPT" => prompt,
      "DATAFORSEO_AI_WEB_ENGINES" => "chatgpt,gemini",
      "DATAFORSEO_DAILY_TASK_LIMIT" => "2", "DATAFORSEO_31_DAY_TASK_LIMIT" => "10"
    }
    with_environment(values) do
      travel_to Time.utc(2026, 5, 31, 12) do
        route = sample_ai_visibility_seo_workflows_path
        settings = SeoWorkflows::AiVisibilitySample.web_settings(@site)
        params = { engine: "chatgpt", revision: settings.fetch(:revision) }

        @membership.update!(role: "viewer")
        get setup_seo_workflows_path
        assert_select "#M5 button", text: "Sample ChatGPT", count: 0
        refute_includes response.body, prompt
        post route, params: params
        assert_response :forbidden
        @membership.update!(role: "owner")
        get setup_seo_workflows_path
        assert_select "#M5 button", text: "Sample ChatGPT"
        assert_includes response.body, prompt
        assert_no_enqueued_jobs(only: SeoAiVisibilitySampleJob) { post route, params: params.merge(revision: "old") }

        assert_enqueued_jobs(1, only: SeoAiVisibilitySampleJob) { post route, params: params }
        sample = @site.source_snapshots.sole
        assert_redirected_to setup_seo_workflows_path(anchor: "M5")
        follow_redirect!
        assert_select "#M5 li", text: /ChatGPT response sample.*Queued for the worker/
        assert_no_enqueued_jobs(only: SeoAiVisibilitySampleJob) { post route, params: params }

        responder = lambda do |host, method, path, body|
          assert_equal ["api.dataforseo.com", "POST", "/v3/ai_optimization/chat_gpt/llm_responses/live"], [host, method, path]
          fields = body.sole
          assert_equal ["Market: GB. #{prompt}", "gpt-4.1-mini", "GB", true, true],
            fields.values_at("user_prompt", "model_name", "web_search_country_iso_code", "web_search", "force_web_search")
          [200, { status_code: 20000, tasks: [{ id: "09041216-1444-0612-0000-7eaf4493f783",
            status_code: 20000, data: fields.merge("se" => "chat_gpt"),
            result: [{ model_name: "gpt-4.1-mini-2025-04-14", web_search: true, items: [
              { type: "message", sections: [{ type: "text", text: "Private generated fixture", annotations: [
                { url: "https://www.heating.example/private-fixture-page" }
              ] }] }
            ] }] }] }]
        end
        stub_provider_http(responder) { 2.times { SeoAiVisibilitySampleJob.perform_now(sample.id, @user.id) } }
        assert_equal 1, @requests.size
        assert_equal true, sample.reload.metrics["site_cited"]
        refute_match(/boiler installer|generated fixture|private-fixture-page/, sample.metrics.to_json)
        get source_snapshot_path(sample)
        assert_select "p", text: /Site link observed: yes/
        get setup_seo_workflows_path
        assert_select "#M5 li", text: /ChatGPT response sample.*Site link observed: yes/
        post route, params: params.merge(engine: "gemini")
        queued = @site.source_snapshots.find_by!(external_id: "gemini-2026-05-31")
        with_environment("DATAFORSEO_AI_WEB_PROMPT" => "Changed public prompt") do
          SeoAiVisibilitySampleJob.perform_now(queued.id, @user.id)
        end
        assert_equal "cancelled", queued.reload.metrics["status"]
        assert_equal 1, @requests.size
      end
      travel_to Time.utc(2026, 6, 1, 10) do
        post run_seo_workflows_path, params: { template: "M5" }
        follow_redirect!
        assert_select "li", text: /ChatGPT response sample.*Site link observed: yes/m
      end
    end
  end

  test "M5 makes a scoped exact Google search and distinguishes absent and incomplete overviews" do
    prompt = "Which plumbers in Bath offer same-day repair?"
    engine = SeoWorkflows::AiVisibilitySample::GOOGLE
    env = { "DATAFORSEO_ENABLED" => "true", "DATAFORSEO_LOGIN" => "fixture", "DATAFORSEO_PASSWORD" => "fixture",
      "DATAFORSEO_AI_SITE_ID" => @site.id.to_s, "DATAFORSEO_AI_SITE_HOST" => @site.host,
      "DATAFORSEO_AI_WEB_COUNTRY" => "GB", "DATAFORSEO_AI_WEB_PROMPT" => prompt, "DATAFORSEO_AI_WEB_ENGINES" => engine,
      "DATAFORSEO_DAILY_TASK_LIMIT" => "2", "DATAFORSEO_31_DAY_TASK_LIMIT" => "5" }

    with_environment(env) do
      assert_nil SeoWorkflows::AiVisibilitySample.web_settings(@site)
      @site.update!(rank_location_verified_at: Time.current, rank_location_name: "Bath,England,United Kingdom",
        rank_location_code: 123, rank_country_code: "GB")
      organic = { "type" => "organic", "url" => "https://heating.example/private-organic" }
      items = [organic, { "type" => "ai_overview", "page" => 1, "items" => [{
        "type" => "ai_overview_element", "text" => "Unstored answer", "references" => [
          { "url" => "https://heating.example/private-article" }, { "url" => "https://other.example/source" }
        ], "links" => [{ "url" => "https://heating.example/private-article" }]
      }] }]
      types = %w[organic ai_overview]
      responder = lambda do |host, method, path, body|
        assert_equal ["api.dataforseo.com", "POST", "/v3/serp/google/organic/live/advanced"], [host, method, path]
        scope = { "keyword" => prompt, "location_code" => 123, "language_code" => "en", "device" => "desktop",
          "os" => "windows", "depth" => 10, "max_crawl_pages" => 1, "load_async_ai_overview" => true }
        assert_equal [scope], body
        [200, { "status_code" => 20000, "tasks" => [{ "id" => "09041216-1444-0612-0000-7eaf4493f783",
          "status_code" => 20000, "data" => scope, "result" => [scope.merge("items" => items, "item_types" => types)] }] }]
      end
      travel_to Time.utc(2026, 6, 2, 10) do
        get setup_seo_workflows_path
        assert_select "#M5 button", text: "Sample Google AI Overview"
        revision = SeoWorkflows::AiVisibilitySample.web_settings(@site).fetch(:revision)
        stub_provider_http(responder) do
          perform_enqueued_jobs(only: SeoAiVisibilitySampleJob) do
            post sample_ai_visibility_seo_workflows_path, params: {engine: engine, revision: revision}
          end
        end
        sample = @site.source_snapshots.sole
        assert_equal ["captured", "provider_payload", 2, true], sample.metrics.values_at("status", "overview_coverage", "citation_count", "site_cited")
        refute_match(/same-day repair|Unstored answer|private-article/, sample.metrics.to_json)
        get evidence_preview_seo_workflows_path(template: "M5")
        assert_select "li", text: /Google AI Overview search sample.*Site link observed: yes across 2 usable citation URLs/
        get source_snapshot_path(sample)
        assert_select "dd", text: "Bath,England,United Kingdom"
      end
      items = [organic]
      travel_to Time.utc(2026, 6, 3, 10) do
        stub_provider_http(responder) do
          sample = SeoWorkflows::AiVisibilitySample.call(site: @site, owner_id: @user.id, engine: engine, country: "GB", prompt: prompt)
          assert_equal ["unavailable", nil], sample.metrics.values_at("overview_coverage", "site_cited")
        end
      end
      types = ["organic"]
      travel_to Time.utc(2026, 6, 4, 10) do
        stub_provider_http(responder) do
          sample = SeoWorkflows::AiVisibilitySample.call(site: @site, owner_id: @user.id, engine: engine, country: "GB", prompt: prompt)
          assert_equal ["no_overview", nil], sample.metrics.values_at("overview_coverage", "site_cited")
        end
      end
    end
  end

  test "M2 collects the exact place in a background job and reports verified weekly coverage" do
    travel_to Time.utc(2026, 6, 1, 10) do
      with_environment(local_data_env("M2")) do
        other = @workspace.sites.create!(name: "Other", host: "other.example", location: "Bath")
        refute LocalSeoData::Collection.enabled?(other, "M2")
        get seo_workflows_path
        assert_select "button", text: "Run now with provider", count: 1
        @membership.update!(role: "manager")
        post run_seo_workflows_path, params: { template: "M2" }
        assert_response :forbidden
        @membership.update!(role: "owner")

        responder = lambda do |host, method, path, body|
          assert_equal ["api.localseodata.com", "POST", "/v1/business/reviews"], [host, method, path]
          assert_equal "ChIJfixturePlace", body.fetch("place_id")
          assert_equal 100, body.fetch("limit")
          reviews = (1..4).flat_map do |week|
            4.times.map do |offset|
              { "date" => "#{Date.new(2026, 5, 31) - week * 7 - offset} 19:42:10 +00:00",
                "rating" => 4, "owner_reply" => "Private reply" }
            end
          end
          reviews.unshift({ "date" => "2026-05-31 12:00:00 +00:00", "rating" => 1,
            "author_name" => "Fixture person", "text" => "Private review", "owner_reply" => nil })
          [200, { status: "success", data: { reviews: reviews, total_reviews: reviews.size } }]
        end
        stub_provider_http(responder) do
          perform_enqueued_jobs { post run_seo_workflows_path, params: { template: "M2" } }
          assert_redirected_to seo_workflows_path
          perform_enqueued_jobs { post run_seo_workflows_path, params: { template: "M2" } }
        end
        assert_equal 1, @requests.size
        run = @site.seo_workflow_runs.sole
        get seo_workflow_path(run)
        assert_select "li", text: /volume fell by more than 40%/
        assert_select "li", text: /1 of the sampled reviews rated 1 or 2 stars had no reply/
        assert_equal "attention", SeoWorkflowNotification.where(seo_workflow_run: run).sole.kind
        evidence = @site.source_snapshots.sole
        assert_select "a[href=?]", source_snapshot_path(evidence)
        refute_match(/Fixture person|Private review|Private reply/, evidence.metrics.to_json)
      end
    end
  end

  test "E3 schedule collects real contract-shaped directory statuses and keeps uncertain checks out of missing listings" do
    travel_to Time.utc(2026, 7, 1, 10) do
      with_environment(local_data_env("E3").merge("LOCALSEODATA_SCHEDULED_TASKS" => "E3")) do
        responder = lambda do |host, method, path, body|
          assert_equal ["api.localseodata.com", "POST", "/v1/audit/citation"], [host, method, path]
          assert_equal "https://heating.example", body.fetch("website")
          assert_equal "none", body.fetch("industry")
          assert_equal 15, body.fetch("directories").length
          [200, { status: "success", data: { details: [
            { directory: "google", status: "inconsistent", name_match: true, address_match: false, phone_match: true,
              listed_address: "Raw private fixture", other_listings: [{ name_match: true, address_match: false, phone_match: false }] },
            { directory: "facebook", status: "check_failed" },
            { directory: "yelp", status: "not_found" },
            { directory: "bing", status: "unverified", name_match: true, address_match: nil, phone_match: true }
          ] } }]
        end
        get seo_workflows_path
        assert_select "button", text: "Enable paid schedule", count: 1
        post schedule_seo_workflows_path, params: { template: "E3", enabled: "1" }
        stub_provider_http(responder) { 2.times { SeoWorkflowScheduleJob.perform_now } }
        assert_equal 1, @requests.size

        run = @site.seo_workflow_runs.sole
        get seo_workflow_path(run)
        assert_select "li", text: /12 unavailable checks and 1 unverified checks/
        assert_select "li", text: /google.*Address mismatch.*Duplicate listings/m
        assert_select "li", text: /yelp.*Missing listing/m
        assert_select "li", text: /facebook.*Missing listing/m, count: 0
        assert_equal "attention", SeoWorkflowNotification.where(seo_workflow_run: run).sole.kind
        refute_includes @site.source_snapshots.sole.metrics.to_json, "Raw private fixture"
      end
    end
  end

  test "uncertain paid review collection remains reserved and provides an authenticated receipt" do
    travel_to Time.utc(2026, 6, 1, 10) do
      with_environment(local_data_env("M2")) do
        stub_provider_http(->(*) { [503, "Temporary"] }) do
          2.times { perform_enqueued_jobs { post run_seo_workflows_path, params: { template: "M2" } } }
        end
        assert_equal 1, @requests.size
        run = @site.seo_workflow_runs.sole
        assert_equal "missing_evidence", run.status
        get seo_workflow_path(run)
        assert_select "a[href=?]", source_snapshot_path(@site.source_snapshots.sole), text: "View collection receipt"
      end
    end
  end

  test "M1 and R1 use verified Local Falcon grids and compare only matched measured pins" do
    travel_to Time.utc(2026, 6, 1, 10) do
      @site.create_local_falcon_connection!(place_id: "ChIJfixturePlace", verified_name: @site.name,
        synced_at: Time.current)
      old = create_falcon_grid("aaaa00000000001", "2026-05-24", [6, 1, 2, nil])
      current = create_falcon_grid("aaaa00000000002", "2026-05-31", [2, 7, 3, 1])
      create_falcon_grid("aaaa00000000003", "2026-05-30", [1, 1, 1, 1], place: "ChIJotherPlace")
      %w[M1 R1].each do |template|
        post run_seo_workflows_path, params: { template: template }
        follow_redirect!
        assert_select "li", text: /1 gained and 1 lost top-three placement across 3 comparable pins/
        assert_select "a[href=?]", source_snapshot_path(current)
      end
      refute_equal old.id, current.id
    end
  end

  test "P2 compares complete packs by CID and opens site-scoped evidence from the report" do
    travel_to Time.utc(2026, 5, 30, 12) do
      enable_competitor_tracking
      @baseline_pack = save_competitor_pack([pack_item("100", "North Heating", 4, reviews: 10),
        pack_item("101", "South Heating", 6), pack_item("102", "West Heating", 7)])
    end
    travel_to Time.utc(2026, 6, 29, 12) do
      @current_pack = save_competitor_pack([pack_item("100", "North Heating Ltd", 6, reviews: 16),
        pack_item("101", "South Heating", 4), pack_item("103", "East Heating", 7),
        pack_item("100", "Sponsored North", 1, paid: true)])
      saved = @current_pack.evidence.fetch(Tracking::GoogleLocalPack::KEY)
      assert_equal "top_three", saved.fetch("coverage")
      refute_match(/Private fixture description|441632960000|partner.example/, saved.to_json)
    end
    travel_to Time.utc(2026, 7, 1, 10) do
      post run_seo_workflows_path, params: { template: "P2" }
      follow_redirect!
      assert_select "li", text: /New in the sampled top three: East Heating/
      assert_select "li", text: /Left the sampled top three: West Heating/
      assert_select "li", text: /North Heating Ltd: position 1 to 2, reviews 10 to 16, sponsored listing observed/
      destination = competitor_capture_seo_workflows_path(capture_id: @current_pack.id)
      assert_select "a[href=?]", destination, text: "View source"
      assert_select "a[href=?]", competitor_capture_seo_workflows_path(capture_id: @baseline_pack.id),
        text: "View comparison sample"
      get destination
      assert_select "li", text: /North Heating Ltd.*Position 2.*16 reviews shown.*Matching sponsored listing observed/m

      other_owner = User.create!(email: "other-p2-owner@example.test", password: "long-provider-test-password")
      other_workspace = Workspace.create!(name: "Other competitor workspace")
      other_workspace.memberships.create!(user: other_owner, role: "owner")
      other_workspace.sites.create!(name: "Other", host: @site.host, location: @site.location)
      delete logout_path
      post login_path, params: { session: { email: other_owner.email, password: "long-provider-test-password" } }
      get destination
      assert_response :not_found
    end
  end

  test "P2 recovers original DataForSEO receipts through the owner workflow and compares monthly observations" do
    env = { "DATAFORSEO_ENABLED" => "true", "DATAFORSEO_LOGIN" => "fixture", "DATAFORSEO_PASSWORD" => "fixture",
      "DATAFORSEO_ALLOWED_SERIES_IDS" => nil }
    packs = [
      [pack_item("100", "North Heating", 2), pack_item("101", "South Heating", 3), pack_item("102", "West Heating", 4)],
      [pack_item("100", "North Heating", 2), pack_item("101", "South Heating", 3), pack_item("103", "East Heating", 4)]
    ]
    receipts = {}
    [Time.utc(2026, 5, 31, 10), Time.utc(2026, 6, 1, 10)].each_with_index do |time, index|
      travel_to time do
        enable_competitor_tracking if index.zero?
        id = format("06051709-1535-0298-0000-%012d", index + 1)
        captured = Tracking::RecordResult.call(series: @competitor_series, captured_at: time, reference: id,
          items: [{ "type" => "organic", "rank_group" => 1, "url" => "https://heating.example/service" }])
        captured.update!(evidence: captured.evidence.except(Tracking::GoogleLocalPack::KEY))
        captured.daily_slot.update!(attempted_at: time, task_id: id, attempt_key: "receipt-#{index}")
        receipts[id] = [captured, packs.fetch(index)]
      end
    end

    with_environment(env) do
      travel_to Time.utc(2026, 6, 1, 12) do
        params = { series_id: @competitor_series.id }
        route = recover_competitor_evidence_seo_workflows_path
        @membership.update!(role: "viewer")
        post route, params: params
        assert_response :forbidden
        @membership.update!(role: "owner")
        get setup_seo_workflows_path
        assert_select "#P2 form[action=?] select option", route, text: /heating repair.*desktop/
        post route, params: { series_id: @competitor_series.id + 10_000 }
        assert_response :not_found

        settings = @competitor_series.settings
        responder = lambda do |host, method, path, _|
          assert_equal ["api.dataforseo.com", "GET"], [host, method]
          id = path.split("/").last
          observation, pack = receipts.fetch(id)
          assert_equal "/v3/serp/google/organic/task_get/advanced/#{id}", path
          data = { device: settings.fetch("device"), os: settings.fetch("os"), se: "google", se_type: "organic",
            tag: observation.daily_slot.attempt_key }
          result = { keyword: settings.fetch("keyword"), location_code: settings.fetch("location_code"),
            language_code: settings.fetch("language"), datetime: observation.captured_at.utc.iso8601, items: pack }
          [200, { status_code: 20000, tasks: [{ id: id, status_code: 20000, data: data, result: [result] }] }]
        end

        stub_provider_http(responder) do
          perform_enqueued_jobs(only: SeoCompetitorEvidenceJob) { post route, params: params }
          assert_redirected_to setup_seo_workflows_path(anchor: "P2")
          perform_enqueued_jobs(only: SeoCompetitorEvidenceJob) { post route, params: params }
        end
        assert_equal 2, @requests.size
        assert_equal [1, 1], receipts.values.map { |observation, _| observation.reload.position }
        get evidence_preview_seo_workflows_path(template: "P2")
        assert_select "li", text: /New in the sampled top three: East Heating.*Left the sampled top three: West Heating/m
        baseline = receipts.values.first.first
        assert_select "a[href=?]", competitor_capture_seo_workflows_path(capture_id: baseline.id), text: "View comparison sample"
        get competitor_capture_seo_workflows_path(capture_id: baseline.id)
        assert_select "li", text: /West Heating.*Position 3/m
      end
    end
  end

  test "P2 withholds entrants and departures when the latest sample is partial" do
    travel_to Time.utc(2026, 5, 30, 12) do
      enable_competitor_tracking
      save_competitor_pack([pack_item("100", "North Heating", 4),
        pack_item("101", "South Heating", 6), pack_item("102", "West Heating", 7)])
    end
    travel_to Time.utc(2026, 6, 28, 12) do
      save_competitor_pack([pack_item("100", "North Heating", 4),
        pack_item("101", "South Heating", 6), pack_item("102", "West Heating", 7)])
    end
    travel_to Time.utc(2026, 6, 29, 12) do
      save_competitor_pack([pack_item("100", "North Heating", 4), pack_item(nil, "No stable identity", 6),
        pack_item("103", "East Heating", 7)])
    end
    travel_to Time.utc(2026, 7, 1, 10) do
      post run_seo_workflows_path, params: { template: "P2" }
      follow_redirect!
      assert_select "li", text: /Identified listings in partial sample/
      assert_select "li", text: /Two complete monthly samples are required/
      refute_includes response.body, "Left the sampled top three"
    end
  end

  test "M4 collects dedicated weekly scans through run-now and scheduling and links comparable evidence" do
    with_environment(lsa_environment) do
      travel_to Time.utc(2026, 6, 1, 10) do
        get seo_workflows_path
        assert_select "button", text: "Run now with provider", count: 1
        assert_select "button", text: "Enable paid schedule", count: 1
        assert_select "p", text: /One dedicated scan per week uses 2 provider credits/
        first = [lsa_row(1, "Market leader", "01225 900001"),
          lsa_row(2, @site.name, "01225-900010"), lsa_row(3, "Earlier rival", "01225 900003")]
        stub_provider_http(lsa_response(first)) do
          perform_enqueued_jobs(only: SeoWorkflowCollectionJob) { post run_seo_workflows_path, params: { template: "M4" } }
        end
        assert_redirected_to seo_workflows_path
        post schedule_seo_workflows_path, params: { template: "M4", enabled: "1" }
      end
      travel_to Time.utc(2026, 6, 8, 10) do
        second = [lsa_row(1, "Market leader", "01225 900001"), lsa_row(2, "Earlier rival", "01225 900003"),
          lsa_row(3, "New rival", "01225 900004"), lsa_row(5, @site.name, "(01225) 900010"),
          lsa_row(6, @site.name, "01225 999999")]
        stub_provider_http(lsa_response(second, field: "results")) { 2.times { SeoWorkflowScheduleJob.perform_now } }

        assert_equal 2, @requests.size
        snapshots = @site.source_snapshots.order(:observed_on)
        latest = snapshots.last
        assert_equal 5, latest.metrics.fetch("listing_position")
        refute_match(/900010|900004|999999/, latest.metrics.to_json)
        run = @site.seo_workflow_runs.order(:period_on).last
        get seo_workflow_path(run)
        assert_select "li", text: /Matched listing at position 5 in 5 returned ads/
        assert_select "li", text: /Previous sample on 2026-06-01: position 2/
        assert_select "li", text: /moved outside the top three/
        assert_select "li", text: /New in the sampled top three: New rival/
        assert_select "a[href=?]", source_snapshot_path(snapshots.first), text: "View comparison sample"
        assert_select "a[href=?]", source_snapshot_path(latest), text: "View source"
        assert_equal "attention", SeoWorkflowNotification.where(seo_workflow_run: run).sole.kind
        get source_snapshot_path(latest)
        assert_response :success
        assert_select "dd", text: "5"
        refute_includes response.body, latest.metrics.fetch("scope_digest")
        get source_snapshot_path(snapshots.first)
        assert_response :success
        assert_select "dd", text: "2"
      end
    end
  end

  test "M4 reserves an unconfirmed scan and distinguishes an ambiguous or empty subsequent sample" do
    with_environment(lsa_environment) do
      travel_to Time.utc(2026, 6, 1, 10) do
        stub_provider_http(lsa_response([], market: "Other market")) do
          2.times { perform_enqueued_jobs(only: SeoWorkflowCollectionJob) { post run_seo_workflows_path, params: { template: "M4" } } }
        end
        assert_equal 1, @requests.size
        run = @site.seo_workflow_runs.sole
        assert_equal "missing_evidence", run.status
        get seo_workflow_path(run)
        assert_select "a[href=?]", source_snapshot_path(@site.source_snapshots.sole), text: "View collection receipt"
      end
      travel_to Time.utc(2026, 6, 8, 10) do
        rows = [lsa_row(1, @site.name, "01225 900010"), lsa_row(3, @site.name, "01225-900010")]
        stub_provider_http(lsa_response(rows)) do
          perform_enqueued_jobs(only: SeoWorkflowCollectionJob) { post run_seo_workflows_path, params: { template: "M4" } }
        end
        get seo_workflow_path(@site.seo_workflow_runs.order(:period_on).last)
        assert_select "li", text: /Multiple returned rows matched/
        refute_includes response.body, "moved outside"
      end
      travel_to Time.utc(2026, 6, 15, 10) do
        stub_provider_http(lsa_response([])) do
          perform_enqueued_jobs(only: SeoWorkflowCollectionJob) { post run_seo_workflows_path, params: { template: "M4" } }
        end
        get seo_workflow_path(@site.seo_workflow_runs.order(:period_on).last)
        assert_select "li", text: /The provider returned no ads in this sample/
        assert_select "a", text: "View comparison sample", count: 0
        assert_equal 0, SeoWorkflowNotification.where(kind: "attention").count
      end
    end
  end

  test "M3 compares same-place live baselines, reports coverage and records only a qualified alert" do
    env = local_data_env("M3").merge("LOCALSEODATA_API_KEY" => "sk_live_fixture", "LOCALSEODATA_SCHEDULED_TASKS" => "M3")
    baseline = { "matched" => true, "place_id" => "ChIJfixturePlace", "name" => "Old Fixture Name",
      "address" => "Private fixture address", "phone" => "01225 900010", "website" => "https://previous.example",
      "categories" => ["Heating", "Plumber"], "hours" => { "Monday" => "Open 9-5" } }
    with_environment(env) do
      travel_to Time.utc(2026, 6, 1, 10) do
        get setup_seo_workflows_path(anchor: "M3")
        assert_select "#M3", text: /Live collection configured/
        stub_provider_http(profile_response(baseline)) do
          perform_enqueued_jobs(only: SeoWorkflowCollectionJob) { post run_seo_workflows_path, params: { template: "M3" } }
        end
        get seo_workflow_path(@site.seo_workflow_runs.sole)
        assert_select "li", text: /This sample establishes a baseline/
        assert_equal "complete", SeoWorkflowNotification.sole.kind
        post schedule_seo_workflows_path, params: { template: "M3", enabled: "1" }
      end
      travel_to Time.utc(2026, 6, 2, 10) do
        changed = baseline.except("address").merge("name" => "New Fixture Name", "phone" => nil,
          "website" => "https://changed.example", "categories" => ["Plumber", "Heating"])
        stub_provider_http(profile_response(changed)) { 2.times { SeoWorkflowScheduleJob.perform_now } }
        assert_equal 2, @requests.size
        run = @site.seo_workflow_runs.order(:period_on).last
        snapshot = @site.source_snapshots.order(:observed_on).last
        refute_match(/New Fixture Name|changed.example|01225/, snapshot.metrics.to_json)

        get seo_workflow_path(run)
        assert_select "li", text: /Checked 5 of 6.*Business name changed, Phone returned empty, Website changed/
        refute_includes response.body, "Address returned empty"
        refute_includes response.body, "Categories changed"
        assert_select "a[href=?]", source_snapshot_path(snapshot), text: "View source"
        assert_select "a[href=?]", source_snapshot_path(@site.source_snapshots.order(:observed_on).first),
          text: "View comparison sample"
        assert_equal "attention", SeoWorkflowNotification.where(seo_workflow_run: run).sole.kind
        get source_snapshot_path(snapshot)
        assert_select "dd", text: "Unavailable"
        refute_includes response.body, snapshot.metrics.fetch("fields").fetch("name").fetch("digest")
      end
      travel_to Time.utc(2026, 6, 3, 10) do
        stub_provider_http(profile_response(baseline.merge("place_id" => "ChIJforeignPlace"))) do
          2.times { SeoWorkflowScheduleJob.perform_now }
        end
        assert_equal 3, @requests.size
        run = @site.seo_workflow_runs.order(:period_on).last
        assert_equal "missing_evidence", run.status
        get seo_workflow_path(run)
        assert_select "a", text: "View collection receipt"
      end
    end
  end

  test "M3 uses the DataForSEO binding, shares the task budget and compares exact-place readings" do
    place_id = "ChIJfixturePlace"
    input = { "keyword" => "place_id:#{place_id}", "location_code" => 2826, "language_code" => "en" }
    env = local_data_env("M3").merge("LOCALSEODATA_API_KEY" => nil,
      "DATAFORSEO_ENABLED" => "true", "DATAFORSEO_LOGIN" => "fixture", "DATAFORSEO_PASSWORD" => "fixture",
      "DATAFORSEO_M3_SITE_ID" => @site.id.to_s, "DATAFORSEO_M3_SITE_HOST" => @site.host,
      "DATAFORSEO_M3_LOCATION_CODE" => "2826", "DATAFORSEO_M3_PLACE_ID" => place_id,
      "DATAFORSEO_DAILY_TASK_LIMIT" => "1", "DATAFORSEO_31_DAY_TASK_LIMIT" => "3",
      "DATAFORSEO_M3_SCHEDULED" => "true")
    timetable = %w[monday tuesday wednesday thursday friday saturday sunday].index_with(nil)
    timetable["monday"] = [{ "open" => { "hour" => 9, "minute" => 0 }, "close" => { "hour" => 17, "minute" => 0 } }]
    profile = { "type" => "google_business_info", "place_id" => place_id, "title" => "Fixture",
      "address" => "Fixture Address", "phone" => "01225 900010", "url" => "https://fixture.example",
      "category" => "Heating", "additional_categories" => ["Plumber"],
      "work_time" => { "work_hours" => { "timetable" => timetable } } }
    responder = lambda do |host, method, path, body|
      assert_equal ["api.dataforseo.com", "POST", "/v3/business_data/google/my_business_info/live", [input]],
        [host, method, path, body]
      [200, { "status_code" => 20000, "tasks" => [{ "status_code" => 20000, "data" => input,
        "result" => [{ "items" => [profile] }] }] }]
    end

    with_environment(env) do
      travel_to Time.utc(2026, 6, 1, 10) do
        get setup_seo_workflows_path
        assert_select "#M3", text: /Live collection configured · DataForSEO/
        stub_provider_http(responder) do
          2.times do
            perform_enqueued_jobs(only: SeoWorkflowCollectionJob) { post run_seo_workflows_path, params: { template: "M3" } }
          end
        end
        assert_equal 1, @requests.size
        assert Tracking::DataForSeoBudget.daily_full?(Time.current)
        get seo_workflow_path(@site.seo_workflow_runs.sole)
        assert_select "li", text: /DataForSEO.*Checked 6 of 6.*establishes a baseline/
        post schedule_seo_workflows_path, params: { template: "M3", enabled: "1" }
      end
      travel_to Time.utc(2026, 6, 2, 10) do
        profile.merge!("url" => "https://updated.example", "phone" => nil)
        timetable["monday"].first["open"]["hour"] = 10
        stub_provider_http(responder) { 2.times { SeoWorkflowScheduleJob.perform_now } }
        assert_equal 2, @requests.size
        run = @site.seo_workflow_runs.order(:period_on).last
        snapshot = @site.source_snapshots.order(:observed_on).last
        assert_equal "DataForSEO", snapshot.provider
        refute_includes snapshot.metrics.to_json, "updated.example"
        get seo_workflow_path(run)
        assert_select "li", text: /Checked 5 of 6.*Website changed, Opening hours changed/
        refute_includes response.body, "Phone returned empty"
        assert_equal "attention", SeoWorkflowNotification.where(seo_workflow_run: run).sole.kind
        get source_snapshot_path(snapshot)
        assert_select "dd", text: "Unavailable"
        refute_includes response.body, snapshot.metrics.fetch("fields").fetch("website").fetch("digest")
      end
      travel_to Time.utc(2026, 6, 3, 10) do
        profile["place_id"] = "ChIJforeignPlace"
        stub_provider_http(responder) { 2.times { SeoWorkflowScheduleJob.perform_now } }
        assert_equal 3, @requests.size
        assert_equal "unconfirmed", @site.source_snapshots.order(:observed_on).last.metrics.fetch("state")
        assert_equal "missing_evidence", @site.seo_workflow_runs.order(:period_on).last.status
      end
      travel_to Time.utc(2026, 6, 4, 10) do
        stub_provider_http(responder) { SeoWorkflowScheduleJob.perform_now }
        assert_equal 3, @requests.size
        assert Tracking::DataForSeoBudget.rolling_full?(Time.current)
      end
    end
  end

  test "M2 submits one DataForSEO task, shows pending collection and reports only exact-place aggregates" do
    place_id = "ChIJfixturePlace"
    id = "06051709-1535-0298-0000-7e1fd2d51236"
    env = local_data_env("M2").merge("LOCALSEODATA_API_KEY" => nil,
      "DATAFORSEO_ENABLED" => "true", "DATAFORSEO_LOGIN" => "fixture", "DATAFORSEO_PASSWORD" => "fixture",
      "DATAFORSEO_M2_SITE_ID" => @site.id.to_s, "DATAFORSEO_M2_SITE_HOST" => @site.host,
      "DATAFORSEO_M2_LOCATION_CODE" => "2826", "DATAFORSEO_M2_PLACE_ID" => place_id,
      "DATAFORSEO_DAILY_TASK_LIMIT" => "2", "DATAFORSEO_31_DAY_TASK_LIMIT" => "3")
    payload = nil
    polls = 0
    result = { "type" => "google_reviews", "place_id" => place_id, "location_code" => 2826,
      "language_code" => "en", "reviews_count" => 1, "items_count" => 1, "items" => [
        { "type" => "google_reviews_search", "review_id" => "private_review_id", "timestamp" => "2026-06-13 15:00:00 +00:00",
          "rating" => { "rating_type" => "Max5", "value" => 1 }, "owner_answer" => nil, "review_text" => "Private review wording" }
      ] }
    responder = lambda do |host, method, path, body|
      assert_equal "api.dataforseo.com", host
      if method == "POST"
        assert_equal "/v3/business_data/google/reviews/task_post", path
        payload = body.sole
        assert_equal ["place_id:#{place_id}", 2826, "en", 100, "newest", 1],
          payload.values_at("keyword", "location_code", "language_code", "depth", "sort_by", "priority")
        assert_match(/\Asearchdesk-m2-\d+\z/, payload.fetch("tag"))
        [200, { "status_code" => 20000, "tasks" => [{ "status_code" => 20100, "id" => id }] }]
      else
        assert_equal "/v3/business_data/google/reviews/task_get/#{id}", path
        polls += 1
        task = { "status_code" => polls == 1 ? 40602 : 20000, "id" => id }
        task.merge!("data" => payload.except("priority"), "result" => [result]) if polls > 1
        [200, { "status_code" => 20000, "tasks" => [task] }]
      end
    end
    with_environment(env) do
      travel_to Time.utc(2026, 6, 15, 10) do
        stub_provider_http(responder) do
          2.times do
            perform_enqueued_jobs(only: SeoWorkflowCollectionJob) { post run_seo_workflows_path, params: { template: "M2" } }
          end
          snapshot = @site.source_snapshots.sole
          report = @site.seo_workflow_runs.sole
          assert_equal "submitted", snapshot.metrics.fetch("state")
          get setup_seo_workflows_path
          assert_select "#M2", text: /Live collection configured · DataForSEO.*Awaiting provider results/
          get seo_workflow_path(report)
          assert_select "p", text: /Awaiting provider results/
          get source_snapshot_path(snapshot)
          refute_includes response.body, id
          with_environment("DATAFORSEO_M2_PLACE_ID" => "ChIJChangedPlace") { SeoWorkflowScheduleJob.perform_now }
          assert_equal 0, polls
          SeoWorkflowScheduleJob.perform_now
          assert_equal "submitted", snapshot.reload.metrics.fetch("state")
          2.times { SeoWorkflowScheduleJob.perform_now }
          assert_equal 2, polls
          assert_equal "captured", snapshot.reload.metrics.fetch("state")
          assert_equal "complete", report.reload.status
          refute_match(/private_review_id|Private review wording|#{id}/, snapshot.metrics.to_json)
          get seo_workflow_path(report)
          assert_select "li", text: /DataForSEO · Google reviews.*1 new reviews.*including 1 one-star reviews/
          assert_equal "attention", SeoWorkflowNotification.where(seo_workflow_run: report).sole.kind
        end
        assert_equal 1, @requests.count { |request| request[1] == "POST" }
      end
    end
  end

  test "R2 and R4 compare the right periods and export links only after approval" do
    captures = {}
    { "2026-03-31" => "Old Heating", "2026-05-31" => "West Heating", "2026-06-24" => "East Heating" }.each_with_index do |(date, name), index|
      travel_to Date.iso8601(date).noon do
        enable_competitor_tracking if index.zero?
        captures[date] = save_competitor_pack([
          pack_item("100", "North Heating", 2), pack_item("101", "South Heating", 3), pack_item((102 + index).to_s, name, 4)
        ])
      end
    end

    ai = @site.source_snapshots.create!(provider: SeoWorkflows::AiVisibilitySample::PROVIDER,
      external_id: "gemini-2026-06-25", title: "Gemini response sample", observed_on: "2026-06-25", scope: "Public sample",
      metrics: { "host" => @site.host, "status" => "captured", "country" => "GB", "model" => "fixture",
        "citation_count" => 2, "site_cited" => true })
    failed = @site.source_snapshots.create!(provider: ai.provider, external_id: "google_ai_overviews-2026-06-25",
      title: "Google AI Overview search sample", observed_on: ai.observed_on, scope: "Reserved",
      metrics: ai.metrics.merge("status" => "unconfirmed"))
    travel_to Time.utc(2026, 6, 26, 10) do
      get evidence_preview_seo_workflows_path(template: "R4")
      assert_select "li", text: /Left the sampled top three: Old Heating/
      assert_select "a[href=?]", source_snapshot_path(ai), text: "View source"
      assert_select "a[href=?]", source_snapshot_path(failed), count: 0
    end

    travel_to Time.utc(2026, 7, 1, 10) do
      { "R2" => ["2026-05-31", "West Heating"], "R4" => ["2026-03-31", "Old Heating"] }.each do |key, (date, expected_departure)|
        post run_seo_workflows_path, params: { template: key }
        follow_redirect!
        assert_select "li", text: /Left the sampled top three: #{expected_departure}/
        baseline = competitor_capture_seo_workflows_path(capture_id: captures.fetch(date).id)
        assert_select "a[href=?]", baseline, text: "View comparison sample"
        assert_select "a[href=?]", source_snapshot_path(ai), text: "View source"
        report = @site.seo_workflow_runs.find_by!(template_key: key)
        assert_equal "awaiting_approval", report.status
        get export_evidence_seo_workflows_path
        refute_includes JSON.parse(response.body).fetch("reports").pluck("template"), key
        patch review_seo_workflow_path(report), params: { decision: "approve" }
        get export_evidence_seo_workflows_path
        exported = JSON.parse(response.body).fetch("reports").find { |entry| entry["template"] == key }.fetch("evidence")
        assert_includes exported.pluck("source_path"), source_snapshot_path(ai)
        assert_includes exported.pluck("comparison_path"), baseline
        refute_includes response.body, "Private fixture description"
      end
    end
  end

  test "R4 saves a 90-day review with dated trends and exports the approved version" do
    place = "ChIJquarterfixture"
    finish = Date.new(2026, 6, 30)
    start = finish - 89
    travel_to start.noon do
      enable_competitor_tracking
      @site.create_local_falcon_connection!(place_id: place, verified_name: @site.name, synced_at: Time.current)
    end
    [start, finish].each_with_index do |day, index|
      travel_to day.noon do
        items = (1..(8 - index * 3)).map do |rank|
          host = rank == (8 - index * 3) ? @site.host : "other.example"
          { "type" => "organic", "rank_group" => rank, "rank_absolute" => rank, "url" => "https://#{host}/service" }
        end
        Tracking::RecordResult.call(series: @competitor_series, captured_at: Time.current, items: items)
        ref = "abc12345678901#{index + 1}"
        @site.source_snapshots.create!(provider: "Local Falcon", external_id: ref, title: "Google Maps scan",
          observed_on: day, keyword: "heating repair", scope: "Existing Google Maps scan for #{@site.host}.",
          metrics: { "place_id" => place, "grid_size" => 1, "arp" => 5 - index * 3, "solv" => index * 100.0 },
          map_grid: { "place_id" => place, "report_key" => ref, "keyword" => "heating repair", "date" => day.iso8601,
            "grid_size" => 1, "radius" => 1, "unit" => "mi",
            "points" => [{ "lat" => 51.0, "lng" => -0.1, "rank" => 5 - index * 3 }] })
        @site.source_snapshots.create!(provider: SeoWorkflows::AiVisibilitySample::PROVIDER, external_id: "gemini-#{day}",
          title: "Gemini response sample", scope: "Public sample", observed_on: day,
          metrics: { "host" => @site.host, "status" => "captured", "country" => "GB", "engine" => "gemini",
            "model" => "fixture", "prompt_digest" => "same-question", "site_cited" => index.positive?, "citation_count" => 2 })
      end
    end
    weeks = SeoWorkflows::WeeklyReviewEvidence.full_weeks(start..finish)
    @site.source_snapshots.create!(provider: SeoWorkflows::EvidenceImport::PROVIDER, external_id: "quarter-review-fixture",
      title: "Review sample", scope: "Fictional review activity", observed_on: finish,
      metrics: { "host" => @site.host, "kind" => "review_activity",
        "records" => weeks.each_with_index.map { |week, i| { "week_ending" => week, "new_reviews" => i + 1,
          "average_rating" => 4.5, "unanswered_low_rating" => i.zero? ? 1 : 0, "new_one_star" => 0 } } })

    travel_to Time.utc(2026, 7, 1, 10) do
      post run_seo_workflows_path, params: { template: "R4" }
      follow_redirect!
      assert_select "h2", text: "90-day summary"
      assert_select "h2", text: "Priorities for the next quarter"
      assert_select ".quarterly-grids figure", count: 2
      assert_select "p", text: /1 organic keyword and device pairs improved, 0 declined, and 0 held steady/
      assert_select "p", text: /from 10 in the first four/
      assert_select "li", text: /Gemini.*Site link absent.*site cited/m
      assert_select "li", text: /heating repair.*8.*5/m
      report = @site.seo_workflow_runs.find_by!(template_key: "R4")
      assert_equal "awaiting_approval", report.status
      get export_evidence_seo_workflows_path
      refute_includes JSON.parse(response.body).fetch("reports").pluck("template"), "R4"

      patch review_seo_workflow_path(report), params: { decision: "approve" }
      get export_evidence_seo_workflows_path
      review = JSON.parse(response.body).fetch("reports").find { |entry| entry["template"] == "R4" }.fetch("quarterly_review")
      assert_equal [start.iso8601, finish.iso8601], review.values_at("start", "end")
      assert_equal 1, review.dig("ranking_counts", "improved")
      assert_equal 1, review.dig("maps", "pin_changes", "improved")
      assert_equal weeks.size, review.dig("reviews", "covered")
      assert_equal [false, true], review.fetch("ai_trends").sole.values_at("first_cited", "last_cited")
      assert_includes (3..5), review.fetch("priorities").size
      assert review.fetch("priorities").all? { |priority| priority["source_path"].present? && priority["measure"].present? }
    end
  end

  test "R1 compares the adjacent weeks, refreshes for a late M2 result and exports one action" do
    place = "ChIJweekfixture"
    [Date.new(2026, 5, 31), Date.new(2026, 6, 7)].each_with_index do |day, index|
      travel_to day.noon do
        if index.zero?
          enable_competitor_tracking
          @site.create_local_falcon_connection!(place_id: place, verified_name: @site.name, synced_at: Time.current,
            result: { "google_cid" => "100" })
        end
        position = 3 + index
        organic = (1..position).map do |rank|
          host = rank == position ? @site.host : "other.example"
          { "type" => "organic", "rank_group" => rank, "rank_absolute" => rank, "url" => "https://#{host}/service" }
        end
        captures = [pack_item("100", @site.name, index.zero? ? 4 : 3, reviews: 15),
          pack_item("101", "South Heating", index.zero? ? 3 : 4), pack_item("102", "West Heating", 5)]
        Tracking::RecordResult.call(series: @competitor_series, captured_at: Time.current, items: [*organic, *captures])
        ref = "78512345678901#{index + 1}"
        @site.source_snapshots.create!(provider: "Local Falcon", external_id: ref, title: "Google Maps scan",
          observed_on: day, keyword: "heating repair", scope: "Existing Google Maps scan for #{@site.host}.",
          metrics: { "place_id" => place, "grid_size" => 1, "arp" => 5 - index, "solv" => 30 + 20 * index },
          map_grid: { "place_id" => place, "report_key" => ref, "keyword" => "heating repair", "date" => day.iso8601,
            "grid_size" => 1, "radius" => 1, "unit" => "mi", "points" => [{ "lat" => 51.0, "lng" => -0.1, "rank" => 5 - index }] })
      end
    end
    report = nil
    travel_to Time.utc(2026, 6, 8, 9) do
      get evidence_preview_seo_workflows_path(template: "R1")
      assert_no_difference -> { @site.seo_workflow_runs.count } do
        get evidence_preview_seo_workflows_path(template: "R1")
      end
      post schedule_seo_workflows_path, params: { template: "R1", enabled: "1" }
      SeoWorkflowScheduleJob.perform_now
      report = @site.seo_workflow_runs.find_by!(template_key: "R1")
      get seo_workflow_path(report)
      assert_select "p", text: /Partial coverage/
      assert_select "p", text: /Organic rankings declined overall across 1 comparable/
      assert_select "p", text: /coverage 50%.*improved from 30/m
      assert_select "p", text: /Position 1.*position 2/m
    end
    travel_to Time.utc(2026, 6, 8, 11) do
      review = @site.source_snapshots.create!(provider: LocalSeoData::DataForSeoCollection::PROVIDER, external_id: "weekly-review-fixture",
        title: "Weekly review activity", scope: "Google review fixture", observed_on: "2026-06-08",
        metrics: { "host" => @site.host, "kind" => "review_activity", "state" => "captured", "scope_digest" => "fixture",
          "period_on" => "2026-06-07", "records" => [
            { "week_ending" => "2026-05-31", "complete_coverage" => true, "new_reviews" => 1,
              "average_rating" => 5, "unanswered_low_rating" => 0, "new_one_star" => 0 },
            { "week_ending" => "2026-06-07", "complete_coverage" => true, "new_reviews" => 3,
              "average_rating" => 4, "unanswered_low_rating" => 1, "new_one_star" => 1 }
          ] })
      2.times { SeoWorkflowScheduleJob.perform_now }
      assert_equal 1, @site.seo_workflow_runs.where(template_key: "R1").count
      assert_equal 1, SeoWorkflowNotification.where(seo_workflow_run: report).count
      get seo_workflow_path(report)
      assert_select "p", text: /Complete coverage/
      assert_select "p", text: /3 new reviews.*improved from 1/m
      assert_select "h2", text: "One next action", count: 1
      assert_select "a[href=?]", source_snapshot_path(review), text: "Open evidence or setup"

      get export_evidence_seo_workflows_path
      bundle = JSON.parse(response.body)
      assert_equal @site.host, bundle.fetch("site_host")
      assert_match(/\A[a-f0-9]{64}\z/, bundle.fetch("site_scope"))
      other_site = Workspace.create!(name: "Other workspace").sites.create!(
        name: "Other business", host: @site.host, location: @site.location)
      assert_not_equal bundle.fetch("site_scope"), SeoWorkflows::EvidenceBundle.new(other_site).build.fetch("site_scope")
      entry = bundle.fetch("reports").find { |item| item["template"] == "R1" }
      assert_equal seo_workflow_path(report), entry.fetch("report_path")
      weekly = entry.fetch("weekly_performance")
      assert_equal ["2026-06-01", "2026-06-07", "2026-05-25", "2026-05-31"],
        weekly.values_at("start", "end", "previous_start", "previous_end")
      assert_equal [3, 4], [weekly.dig("organic", "changes", 0, "previous", "position"),
        weekly.dig("organic", "changes", 0, "current", "position")]
      assert_equal [1, 3], [weekly.dig("reviews", "previous", "new_reviews"), weekly.dig("reviews", "current", "new_reviews")]
      assert_equal source_snapshot_path(review), weekly.dig("next_action", "source_path")

      other_site.source_snapshots.create!(provider: SeoWorkflows::EvidenceImport::PROVIDER, title: "Foreign export marker",
        external_id: "other-workspace-private", scope: "Fixture", observed_on: Date.current, metrics: { "host" => other_site.host })
      get download_brain_vault_seo_workflows_path
      assert_response :success
      assert_equal "application/zip", response.media_type
      assert_includes response.headers.fetch("Cache-Control"), "no-store"
      assert_includes response.headers.fetch("Content-Disposition"), "heating.example-local-seo-brain.zip"
      files, errors, status = Open3.capture3("python3", "-c", <<~'PYTHON', stdin_data: response.body, binmode: true)
        import io, sys, zipfile
        with zipfile.ZipFile(io.BytesIO(sys.stdin.buffer.read())) as archive:
            for name in archive.namelist():
                if name.endswith((".md", ".json")):
                    print(name)
                    if "Searchdesk R1 " in name or "/.raw/sources/searchdesk/" in name:
                        sys.stdout.buffer.write(archive.read(name) + b"\n")
      PYTHON
      assert status.success?, errors
      assert_includes files, "wiki/reports/Searchdesk R1 2026-06-07.md"
      assert_includes files, "wiki/sources/Searchdesk M1 "
      assert_includes files, "New reviews 3"
      assert_includes files, "Review the unanswered low-rated Google reviews in M2"
      assert_not_includes files, "other-workspace-private"

      Tracking::RecordResult.call(series: @competitor_series, captured_at: Time.current,
        items: [{ "type" => "organic", "rank_group" => 1, "rank_absolute" => 1, "url" => "https://heating.example/service" }])
      get evidence_preview_seo_workflows_path(template: "R1")
      assert_select "p", text: /Weekly review totals are available after the week closes/
      assert_select "p", text: /Keep tracking the same keywords and devices next week/
    end
  end

  test "Brain vault download gives an empty-site hint and requires workspace ownership" do
    get download_brain_vault_seo_workflows_path
    assert_redirected_to seo_workflows_path(vault: "empty", anchor: "workflow-evidence")
    follow_redirect!
    assert_select "#workflow-evidence[open] a[href=?]", download_brain_vault_seo_workflows_path
    assert_select "[role=status]", text: /Save an R1 weekly report or M1 Maps grid/

    @membership.update!(role: "viewer")
    get download_brain_vault_seo_workflows_path
    assert_response :forbidden
  end

  private

  def create_falcon_grid(key, date, ranks, place: "ChIJfixturePlace")
    points = [[51.1, -1.1], [51.1, -1.0], [51.2, -1.1], [51.2, -1.0]].zip(ranks).map do |(lat, lng), rank|
      { "lat" => lat, "lng" => lng, "rank" => rank }
    end
    @site.source_snapshots.create!(provider: "Local Falcon", external_id: key, title: "Fictional Maps scan",
      observed_on: date, keyword: "heating repair",
      scope: "Existing Google Maps scan for #{@site.host}. Local Falcon grid summary for one place. Dates follow the provider’s report.",
      metrics: { "place_id" => place, "grid_size" => 2, "radius" => 1, "distance_unit" => "mi", "solv" => 75 },
      map_grid: { "report_key" => key, "place_id" => place, "keyword" => "heating repair", "date" => date,
        "grid_size" => 2, "radius" => 1, "unit" => "mi", "points" => points })
  end

  def local_data_env(task)
    {
      "LOCALSEODATA_API_KEY" => "sk_test_fixture", "LOCALSEODATA_SITE_ID" => @site.id.to_s,
      "LOCALSEODATA_SITE_HOST" => @site.host, "LOCALSEODATA_ALLOWED_TASKS" => task,
      "LOCALSEODATA_SCHEDULED_TASKS" => nil, "LOCALSEODATA_BUSINESS_NAME" => @site.name,
      "LOCALSEODATA_LOCATION" => "Bath, England", "LOCALSEODATA_PLACE_ID" => "ChIJfixturePlace",
      "LOCALSEODATA_ADDRESS" => "1 Example Street, Bath", "LOCALSEODATA_PHONE" => "+44 1632 960000"
    }
  end

  def enable_competitor_tracking
    @site.update!(tracking_mode: "dataforseo", rank_location_verified_at: Time.current, rank_location_name: @site.location,
      rank_location_code: 123, rank_country_code: "GB")
    @competitor_series = Tracking::Enrollment.call(site: @site, phrase: "heating repair", devices: ["desktop"]).tracking_series.sole
  end

  def pack_item(cid, name, position, reviews: nil, paid: false)
    { "type" => "local_pack", "page" => 1, "position" => "left", "is_paid" => paid, "rank_absolute" => position,
      "cid" => cid, "title" => name, "description" => "Private fixture description", "phone" => "+441632960000",
      "url" => "https://partner.example/", "rating" => { "rating_type" => "Max5", "value" => 4.5, "rating_max" => 5, "votes_count" => reviews } }
  end

  def save_competitor_pack(pack)
    organic = { "type" => "organic", "rank_group" => 1, "rank_absolute" => 8, "url" => "https://heating.example/service" }
    Tracking::RecordResult.call(series: @competitor_series, captured_at: Time.current, items: [organic, *pack])
  end

  def profile_response(profile)
    lambda do |host, method, path, body|
      assert_equal ["api.localseodata.com", "POST", "/v1/business/profile"], [host, method, path]
      assert_equal({ "business_name" => @site.name, "location" => "Bath, England", "place_id" => "ChIJfixturePlace" }, body)
      [200, { "status" => "success", "data" => profile }]
    end
  end

  def lsa_environment
    local_data_env("M4").merge("LOCALSEODATA_API_KEY" => "sk_live_fixture", "LOCALSEODATA_SCHEDULED_TASKS" => "M4",
      "LOCALSEODATA_LSA_KEYWORD" => "boiler repair", "LOCALSEODATA_LSA_PHONE" => "01225 900010")
  end

  def lsa_row(position, name, phone)
    { position: position, business_name: name, phone: phone }
  end

  def lsa_response(rows, field: "ads", market: "Bath, England")
    lambda do |host, verb, path, body|
      assert_equal ["api.localseodata.com", "POST", "/v1/serp/lsa"], [host, verb, path]
      assert_equal({ "keyword" => "boiler repair", "location" => "Bath, England" }, body)
      [200, { "status" => "success", field => rows, "search_metadata" => {
        "keyword" => "boiler repair", "location" => market
      } }]
    end
  end

  def prepare_crawl
    SiteAudit.create!(site: @site, host: @site.host, status: "complete", trigger_kind: "manual", finished_at: 1.day.ago)
  end

  def use_google_environment
    values = {
      "GOOGLE_BUSINESS_CLIENT_ID" => "fixture-business-client",
      "GOOGLE_BUSINESS_CLIENT_SECRET" => "fixture-business-secret",
      "SEARCHDESK_GBP_WORKSPACE_ID" => @workspace.id.to_s
    }
    with_environment(values) { yield }
  end

  def with_environment(values)
    original = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    original&.each { |key, value| ENV[key] = value }
  end

  def with_http(run_job: true, &responder)
    stub_provider_http(responder) do
      if run_job
        2.times { SeoWorkflowNotificationsJob.perform_now }
      else
        exercise_google_workflows
      end
    end
  end

  def stub_provider_http(responder)
    requests = @requests
    transport = Class.new(Net::HTTP) do
      define_method(:start) { |&block| block.call(self) }
      define_method(:request) do |req, &receive|
        body = JSON.parse(req.body) if req.body.present? && req["Content-Type"] == "application/json"
        requests << [address, req.method, req.path, body]
        status, payload = responder.call(address, req.method, req.path, body)
        reply = Net::HTTPResponse::CODE_TO_OBJ.fetch(status.to_s).new("1.1", status.to_s, "Fixture")
        text = payload.is_a?(String) ? payload : JSON.generate(payload)
        reply.define_singleton_method(:read_body) { |&read| read.call(text) }
        receive.call(reply)
        reply
      end
    end
    stub_const(Net, :HTTP, transport) { yield }
  end

  def exercise_google_workflows
    post authorize_business_profile_path
    auth = URI(response.location)
    fields = URI.decode_www_form(auth.query).to_h
    assert_equal "fixture-business-client", fields["client_id"]
    assert_equal "S256", fields["code_challenge_method"]
    assert_equal GoogleBusiness::Client::SCOPE, fields["scope"]
    get callback_business_profile_path, params: { state: fields.fetch("state"), code: "fixture-code" }
    assert_redirected_to business_profile_path

    patch business_profile_path, params: { account_id: "101", location_id: "999" }
    assert_nil @site.reload.business_profile_connection.location_id
    patch business_profile_path, params: { account_id: "101", location_id: "202" }
    assert_redirected_to business_profile_path
    post inspect_live_business_profile_path
    assert_response :success
    assert_select "li", text: /fixture-review.*Unanswered/
    refute_includes response.body, "Private Reviewer"

    {
      "E1" => ["post_brief", "service,approved_detail\nHeating,We check boiler efficiency\n"],
      "E2" => ["review_queue", "review_ref,rating\nfixture-review,4\nalready-answered,4\n"]
    }.each do |key, (kind, csv)|
      upload(kind, csv)
      post run_seo_workflows_path, params: { template: key }
      run = @site.seo_workflow_runs.find_by!(template_key: key)
      grant = @site.reload.business_profile_connection.grant_revision
      assert_no_difference "BusinessProfilePublication.count" do
        post publish_seo_workflow_path(run), params: { row_index: "0", grant: grant }
      end
      patch review_seo_workflow_path(run), params: { decision: "approve" }
      assert_no_difference "BusinessProfilePublication.count" do
        post publish_seo_workflow_path(run), params: { row_index: "0", grant: "stale" }
      end
      get seo_workflow_path(run)
      assert_select "button", text: /Publish this .* to Google/
      2.times { post publish_seo_workflow_path(run), params: { row_index: "0", grant: grant } }
      assert_equal "published", BusinessProfilePublication.find_by!(seo_workflow_run: run, row_index: 0).status
      if key == "E2"
        post publish_seo_workflow_path(run), params: { row_index: "1", grant: grant }
        assert_equal "blocked", BusinessProfilePublication.find_by!(seo_workflow_run: run, row_index: 1).status
        refute @requests.any? { |row| row[1] == "PUT" && row[2].include?("already-answered") }
      end
    end
  end

  def upload(kind, csv)
    Tempfile.create(["fixture", ".csv"]) do |file|
      file.write(csv)
      file.flush
      post import_evidence_seo_workflows_path, params: { kind: kind, observed_on: "2026-05-31",
        export: Rack::Test::UploadedFile.new(file.path, "text/csv") }
      assert_response :see_other
    end
  end

  def google_response(host, method, path, body)
    case host
    when "oauth2.googleapis.com"
      [200, { "access_token" => "fixture-access", "refresh_token" => "test-google-refresh", "expires_in" => 3600,
              "scope" => GoogleBusiness::Client::SCOPE }]
    when "mybusinessbusinessinformation.googleapis.com"
      assert_match(%r{\A/v1/accounts/101/locations\?}, path)
      [200, { "locations" => [{ "name" => "locations/202", "title" => "Fictional heating", "websiteUri" => "https://heating.example" }] }]
    when "mybusiness.googleapis.com"
      if method == "POST" && path.end_with?("/localPosts")
        assert_match(/We check boiler efficiency/, body.fetch("summary"))
        [200, { "name" => "accounts/101/locations/202/localPosts/fixture-post" }]
      elsif method == "PUT" && path.end_with?("/reviews/fixture-review/reply")
        assert_match(/Thank you/, body.fetch("comment"))
        [200, { "comment" => body.fetch("comment"), "updateTime" => "2026-06-01T10:00:00Z" }]
      elsif path.include?("/reviews/already-answered?")
        [200, { "reviewId" => "already-answered", "starRating" => "FOUR", "reviewReply" => { "updateTime" => "2026-05-31T10:00:00Z" } }]
      elsif path.include?("/reviews/fixture-review?")
        [200, { "reviewId" => "fixture-review", "starRating" => "FOUR" }]
      else
        assert_match(/fields=reviews\(reviewId,starRating/, path)
        [200, { "reviews" => [{ "reviewId" => "fixture-review", "starRating" => "FOUR", "reviewer" => { "displayName" => "Private Reviewer" } }] }]
      end
    else
      flunk("Unexpected provider")
    end
  end
end
