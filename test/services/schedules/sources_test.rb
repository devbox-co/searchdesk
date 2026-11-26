require "test_helper"

class SchedulesSourcesTest < ActiveSupport::TestCase
  PLACE = "VerifiedPlace12345"
  setup do
    @site = Workspace.create!(name: "Schedules").sites.create!(name: "Bakery", host: "bakery.test",
      location: "Leeds", time_zone: "Europe/London")
    @now = Time.utc(2026, 7, 16, 12)
    @env = %w[GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET].index_with { |name| ENV[name] }
    ENV.update("GOOGLE_CLIENT_ID" => "test-client", "GOOGLE_CLIENT_SECRET" => "test-secret")
  end

  teardown { @env.each { |key, value| ENV[key] = value } }

  def rows
    Schedules::Sources.new(site: @site.reload, now: @now).rows
  end

  def row(key)
    rows.find { |entry| entry[:key] == key }
  end

  def connect_falcon
    @site.create_local_falcon_connection!(status: "connected", place_id: PLACE, refresh_token: "test-refresh",
      last_attempt_at: @now - 6.minutes, synced_at: @now - 5.minutes, result: {"campaigns" => 0})
  end

  def campaign(key, site: @site, day: @now.to_date, place: PLACE, frequency: "every week", status: "scheduled",
      last: nil, upcoming: @now + 3.days, source_path: nil)
    site.source_snapshots.create!(external_id: "campaign-#{key}-#{day}", provider: "Local Falcon",
      observed_on: day, title: "Maps campaign · #{key}", scope: "Verified single location",
      source_path: source_path, metrics: {place_id: place, locations: 1, frequency: frequency, status: status,
        last_run: last&.iso8601, next_run: upcoming&.iso8601})
  end

  test "new sites see setup states without expecting a scheduled import or campaign" do
    result = rows
    assert_equal 4, result.size
    assert_equal ["Not connected"], result.select { |r| r[:group] == :collection }.pluck(:status).uniq
    assert result.all? { |r| r[:last_at].nil? && r[:next_at].nil? }
    assert_equal "Unconfirmed", result.last[:status]
  end

  test "Google and Falcon use their own success intervals and attempts control delayed retries" do
    s = @site.create_search_console_connection!(status: "connected", property: "sc-domain:bakery.test",
      refresh_token: "ok", synced_at: @now - 2.hours, sync_started_at: @now - 3.hours)
    a = @site.create_analytics_connection!(status: "delayed", property_id: "1234", verified_host: @site.host,
      grant_key: SecureRandom.uuid, refresh_token: "ok", synced_at: @now - 3.days, sync_started_at: @now - 30.minutes)
    f = connect_falcon
    assert_equal s.synced_at + 24.hours, row("search-console")[:next_at]
    assert_equal s.synced_at, row("search-console")[:last_at]
    assert_equal "Retry pending", row("analytics")[:status]
    assert_equal a.sync_started_at, row("analytics")[:last_at]
    assert_includes row("analytics")[:detail], "Last successful sync"
    assert_equal @now + 30.minutes, row("analytics")[:next_at]
    assert_equal f.synced_at + 23.hours, row("local-falcon")[:next_at]
    assert_equal "None reported", row("falcon-campaigns")[:status]
    s.update!(status: "reconnect")
    assert_equal "Reconnect", row("search-console")[:status]
    assert_nil row("search-console")[:next_at]
    a.update!(sync_key: "claim", sync_started_at: @now - 1.minute)
    assert_equal "Sync started", row("analytics")[:status]
    a.update!(sync_started_at: @now - 14.minutes)
    assert_equal "Awaiting recovery", row("analytics")[:status]
    a.update!(verified_host: "other.test")
    assert_equal "Setup needed", row("analytics")[:status]
  end

  test "campaigns use provider timestamps and exact membership for the last successful place-scoped sync" do
    f = connect_falcon
    key = "a" * 15
    active = campaign(key, last: @now - 4.days)
    campaign("b" * 15) # Removed in a later sync on the same day
    day = @now.to_date - 1
    campaign(key, day: day)
    f.update!(result: {"campaigns" => 1, "campaign_snapshot_ids" => [active.external_id]})
    external = rows.select { |r| r[:group] == :external }
    assert_equal 1, external.length
    c = external.first
    assert_equal "Every week", c[:frequency]
    assert_equal @now - 4.days, c[:last_at]
    assert_equal @now + 3.days, c[:next_at]
    assert_equal "Scheduled by Local Falcon", c[:next_label]
    assert_includes c[:detail], "12:55 BST"
    assert_equal "Scheduled", c[:status]
    active.update!(metrics: active.metrics.merge("next_run" => (@now - 1.hour).iso8601))
    stale = row("campaign-#{key}")
    assert_equal "Needs refresh", stale[:status]
    assert_nil stale[:next_at]
    assert_includes stale[:next_label], "Last forecast"
    f.update!(status: "reconnect")
    assert_empty rows.select { |r| r[:name] == key }
  end

  test "legacy imports require the right site place date source and complete campaign count" do
    f = connect_falcon
    f.update!(result: {"campaigns" => 1})
    key = "a" * 15
    campaign(key, day: @now.to_date - 1)
    campaign("b" * 15, place: "DifferentPlace123")
    campaign("c" * 15, source_path: "archive")
    foreign = @site.workspace.sites.create!(name: "Elsewhere", host: "other.test", location: "York")
    campaign("d" * 15, site: foreign)
    assert_equal "Unconfirmed", row("falcon-campaigns")[:status]
    campaign(key, status: "paused")
    paused = row("campaign-#{key}")
    assert_equal "Paused", paused[:status]
    assert_nil paused[:next_at]
    campaign("e" * 15)
    assert_equal "Unconfirmed", row("falcon-campaigns")[:status]
    f.update!(result: {"campaigns" => 0})
    assert_equal "None reported", row("falcon-campaigns")[:status]
  end
end
