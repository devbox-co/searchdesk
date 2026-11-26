require "test_helper"

class TrackingScheduleJobTest < ActiveJob::TestCase
  setup do
    @site = Workspace.create!(name: "Example workspace").sites.create!(name: "Business", host: "business.test",
      location: "Example town", language: "en", time_zone: "UTC", tracking_mode: "manual")
  end

  test "scheduler fills missed local dates once and does not dispatch manual imports" do
    travel_to Time.utc(2026, 4, 1, 15) do
      Tracking::Enrollment.call(site: @site, phrase: "Service", devices: ["mobile"])
    end
    travel_to Time.utc(2026, 4, 4, 9) do
      2.times { TrackingScheduleJob.perform_now }
      slots = @site.keywords.first.tracking_series.first.daily_slots.order(:day)
      assert_equal %w[missing missing missing pending], slots.pluck(:status)
      assert_equal 4, slots.count
      assert_no_enqueued_jobs only: TrackingCollectJob
    end
  end

  test "paid collector stays disabled until explicitly enabled" do
    @site.update!(tracking_mode: "dataforseo", rank_location_code: 123, rank_location_name: @site.location, rank_country_code: "GB", rank_location_verified_at: Time.current)
    series = Tracking::Enrollment.call(site: @site, phrase: "Service", devices: ["mobile"]).tracking_series.first
    slot = series.daily_slots.first
    old = ENV.delete("DATAFORSEO_ENABLED")
    TrackingCollectJob.perform_now(slot.id)
    assert_equal "held", slot.reload.status
    assert_nil slot.attempted_at
    assert_nil slot.task_id
  ensure
    ENV["DATAFORSEO_ENABLED"] = old if old
  end
  test "an owner pause or a mode change after reservation prevents the external submission" do
    @site.update!(tracking_mode: "dataforseo", rank_location_code: 123, rank_location_name: @site.location,
      rank_country_code: "GB", rank_location_verified_at: Time.current)
    series = Tracking::Enrollment.call(site: @site, phrase: "Service", devices: ["mobile"]).tracking_series.first
    slot = series.daily_slots.first
    job = TrackingCollectJob.new
    provider = Object.new
    def provider.submit(_slot)
      raise "unexpected external call"
    end
    keys = %w[DATAFORSEO_ENABLED DATAFORSEO_LOGIN DATAFORSEO_PASSWORD DATAFORSEO_DAILY_TASK_LIMIT]
    previous = keys.to_h { |key| [key, ENV[key]] }
    ENV.update("DATAFORSEO_ENABLED" => "true", "DATAFORSEO_LOGIN" => "fixture", "DATAFORSEO_PASSWORD" => "fixture", "DATAFORSEO_DAILY_TASK_LIMIT" => "100")
    assert job.send(:reserve_submission, slot)
    series.update!(paused: true)
    job.send(:submit_reserved, slot, provider)
    assert_nil slot.reload.attempted_at
    series.update!(paused: false)
    assert job.send(:reserve_submission, slot)
    @site.update!(tracking_mode: "manual")
    job.send(:submit_reserved, slot, provider)
    assert_nil slot.reload.task_id
    assert_nil slot.attempted_at
  ensure
    previous&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  test "a lost submission response can be recovered by correlation and never submitted twice" do
    @site.update!(tracking_mode: "dataforseo", rank_location_code: 123, rank_location_name: @site.location,
      rank_country_code: "GB", rank_location_verified_at: Time.current)
    series = Tracking::Enrollment.call(site: @site, phrase: "Service", devices: ["mobile"]).tracking_series.first
    slot = series.daily_slots.first
    keys = %w[DATAFORSEO_ENABLED DATAFORSEO_LOGIN DATAFORSEO_PASSWORD DATAFORSEO_DAILY_TASK_LIMIT]
    old = keys.to_h { |key| [key, ENV[key]] }
    ENV.update("DATAFORSEO_ENABLED" => "true", "DATAFORSEO_LOGIN" => "fixture", "DATAFORSEO_PASSWORD" => "fixture", "DATAFORSEO_DAILY_TASK_LIMIT" => "100")
    attempts = []
    provider = Object.new
    provider.define_singleton_method(:submit) do |s|
      attempts << s.attempt_key
      raise Tracking::DataForSeo::Unavailable, "Timeout after provider acceptance"
    end
    recovered_id = SecureRandom.uuid
    provider.define_singleton_method(:recover) { |s| recovered_id if s.attempt_key == attempts.first }
    job = TrackingCollectJob.new
    job.define_singleton_method(:provider_adapter) { provider }
    job.perform(slot.id)
    assert_equal "held", slot.reload.status
    assert slot.attempted_at
    assert slot.attempt_key.present?
    slot.update!(retry_after: 1.second.ago)
    job.perform(slot.id)
    assert_equal ["submitted", recovered_id], [slot.reload.status, slot.task_id]
    assert_equal 1, attempts.size
  ensure
    old&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end
end
