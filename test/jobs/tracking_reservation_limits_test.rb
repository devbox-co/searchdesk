require "test_helper"

class TrackingReservationLimitsTest < ActiveJob::TestCase
  setup do
    @keys = %w[DATAFORSEO_DAILY_TASK_LIMIT DATAFORSEO_31_DAY_TASK_LIMIT DATAFORSEO_ALLOWED_SERIES_IDS DATAFORSEO_ENABLED DATAFORSEO_LOGIN DATAFORSEO_PASSWORD]
    @previous = @keys.to_h { |key| [key, ENV[key]] }
    ENV.delete("DATAFORSEO_ALLOWED_SERIES_IDS")
    ENV.update("DATAFORSEO_DAILY_TASK_LIMIT" => "42", "DATAFORSEO_31_DAY_TASK_LIMIT" => "1")
    @job = TrackingCollectJob.new
  end

  teardown do
    @previous.each { |key, value| ENV[key] = value }
  end

  test "a reservation on the 32nd UTC date still counts across sites until 31 full days have elapsed" do
    now = Time.utc(2026, 11, 24, 8, 0)
    travel_to(now) do
      early = slot_for("other").tap do |slot|
        slot.update!(day: (now - 31.days).to_date, status: "held", attempted_at: now - 31.days + 1.minute, attempt_key: SecureRandom.uuid)
      end
      current = slot_for("current")
      assert_not @job.send(:reserve_submission, current)
      assert_equal "Rolling 31-day provider task limit reached", current.reload.reason
      assert_nil current.attempted_at
      assert_nil current.attempt_key
      early.update!(attempted_at: now - 31.days)
      assert @job.send(:reserve_submission, current)
      assert_equal now, current.reload.attempted_at
      key = current.attempt_key
      assert_not @job.send(:reserve_submission, current)
      assert_equal key, current.reload.attempt_key
    end
  end

  test "the independent UTC day and rolling limits each hold new tasks and malformed limits fail closed" do
    travel_to Time.utc(2026, 11, 24, 20) do
      existing = slot_for("one")
      remaining = slot_for("two")
      assert @job.send(:reserve_submission, existing)
      ENV.update("DATAFORSEO_DAILY_TASK_LIMIT" => "1", "DATAFORSEO_31_DAY_TASK_LIMIT" => "1302")
      assert_not @job.send(:reserve_submission, remaining)
      assert_equal "Daily provider task limit reached", remaining.reload.reason
      ENV["DATAFORSEO_DAILY_TASK_LIMIT"] = "42"
      ENV["DATAFORSEO_31_DAY_TASK_LIMIT"] = "1302-malformed"
      assert_equal 0, Tracking::DataForSeo.rolling_task_limit
      assert_not @job.send(:reserve_submission, remaining)
      ENV.delete("DATAFORSEO_31_DAY_TASK_LIMIT")
      assert_equal 1302, Tracking::DataForSeo.rolling_task_limit
      assert @job.send(:reserve_submission, remaining)
    end
  end

  test "only exact approved series can reserve and withdrawal after reservation prevents the provider call" do
    allow = slot_for("selected")
    other = slot_for("excluded")
    ENV.update("DATAFORSEO_ALLOWED_SERIES_IDS" => "#{allow.tracking_series_id}",
      "DATAFORSEO_ENABLED" => "true", "DATAFORSEO_LOGIN" => "fixture", "DATAFORSEO_PASSWORD" => "fixture")
    assert_not @job.send(:reserve_submission, other)
    assert_equal "This series is outside the authorized provider scope", other.reload.reason
    assert_nil other.attempted_at
    assert @job.send(:reserve_submission, allow)
    ENV["DATAFORSEO_ALLOWED_SERIES_IDS"] = "#{other.tracking_series_id}"
    provider = Object.new
    def provider.submit(_)
      raise "Provider submission outside the approved scope"
    end
    @job.send(:submit_reserved, allow, provider)
    assert_nil allow.reload.attempted_at
    assert_nil allow.attempt_key
    assert_nil allow.task_id
  end

  test "blank, partially malformed and out-of-range series lists block the entire submission scope" do
    [ "", " ", "9,word", "9,", "*", "0,9", "9,9223372036854775808" ].each do |scope|
      ENV["DATAFORSEO_ALLOWED_SERIES_IDS"] = scope
      assert_not Tracking::DataForSeo.series_allowed?(9)
    end
    ENV["DATAFORSEO_ALLOWED_SERIES_IDS"] = " 9, 19 "
    assert Tracking::DataForSeo.series_allowed?(9)
    assert_not Tracking::DataForSeo.series_allowed?(1)
    ENV.delete("DATAFORSEO_ALLOWED_SERIES_IDS")
    assert Tracking::DataForSeo.series_allowed?(1)
  end

  private

  def slot_for(label)
    site = Workspace.create!(name: label).sites.create!(name: label, host: "#{label}.example",
      location: "Example town", time_zone: "UTC", tracking_mode: "dataforseo", rank_location_code: 123,
      rank_country_code: "GB", rank_location_name: "Example town", rank_location_verified_at: Time.current)
    Tracking::Enrollment.call(site: site, phrase: "repairs", devices: ["mobile"]).tracking_series.sole.daily_slots.sole
  end
end
