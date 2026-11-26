require "test_helper"

class GooglePlacementTest < ActionDispatch::IntegrationTest
  setup do
    user = User.create!(email: "placements@example.test", password: "reasonable-example-pass")
    workspace = Workspace.create!(name: "Placement workspace")
    workspace.memberships.create!(user:, role: "owner")
    @site = create_site(workspace)
    @profile = @site.create_local_falcon_connection!(place_id: "ChIJfirstExample", verified_name: "Example Heating",
      synced_at: Time.current, result: {"google_cid" => "12345"})
    post login_path, params: {session: {email: user.email, password: "reasonable-example-pass"}}
  end

  test "rankings and history show the highest verified result and two dated comparisons" do
    first = Date.current - 9
    travel_to(first.noon) do
      @keyword = Tracking::Enrollment.call(site: @site, phrase: "heating repair")
      @desktop, @mobile = %w[desktop mobile].map { |device| @keyword.tracking_series.find_by!(device:) }
      record(@desktop, winner: 3)
      record(@mobile, winner: 9)
    end
    travel_to((first + 7).noon) { record(@desktop, winner: 2) }
    travel_to((first + 8).noon) { record(@desktop, rows: 2, winner: 9) }
    travel_to((first + 9).noon) do
      competitor = listing("12346", 1).merge("title" => @profile.verified_name, "url" => "https://example.test/")
      paid = listing("12345", 2).merge("is_paid" => true)
      result = record(@desktop, winner: 3, additions: [competitor, paid, listing("12345", 3)])
      assert_equal [3, "https://example.test/winner"], [result.position, result.winning_url]
      assert_equal [3, "local_pack"], result.evidence.fetch("google_placement").values_at("position", "type")

      get rankings_path(source: "local", device: "desktop")
      assert_response :success
      assert_select "#tracking_series_#{@desktop.id} .rank-placement" do
        assert_select ".rank-value", text: "#3"
        assert_select ".rank-feature", text: "Local pack"
        assert_select "a[href*='query_place_id=ChIJfirstExample']", text: "Example Heating"
        assert_select "[title='Up 3']"
        assert_select "[title='Up 4']"
        assert_select "small", text: "#{(first + 7).strftime('%d %b %Y')} · #6"
      end
      assert_select "#tracking_series_#{@desktop.id} .rank-watchlist-organic small", text: "Started at #3 · #{first.strftime('%d %b %Y')}"
      get rankings_path(source: "local", device: "desktop", day: first + 7)
      assert_select "#tracking_series_#{@desktop.id} .rank-placement" do
        assert_select "dt", count: 1, text: "Since last check and start"
        assert_select ".rank-placement-comparisons .rank-change", text: "Up 1", count: 1
        assert_select ".rank-placement-comparisons small", text: "#{first.strftime('%d %b %Y')} · #7", count: 1
      end

      get keyword_path(@keyword, device: "desktop", range: "7")
      assert_select ".rank-placement [title='Up 4']"
      assert_select ".rank-placement", text: "No comparable result"

      get rankings_path(source: "local", device: "mobile")
      assert_select ".rank-placement", text: "No comparable result"
    end
  end

  test "outside coverage and a changed profile never invent a numeric delta" do
    day = Date.current - 3
    travel_to(day.noon) do
      @series = Tracking::Enrollment.call(site: @site, phrase: "heating repair", devices: ["desktop"]).tracking_series.sole
      record(@series)
    end
    travel_to((day + 1).noon) { record(@series, winner: 4, additions: [listing("12345", 2)]) }
    travel_to((day + 2).noon) do
      @profile.update!(place_id: "ChIJsecondExample", result: {})
      record(@series, winner: 3)
    end
    first, second, third = @series.daily_slots.order(:day).to_a
    results = Tracking::PlacementHistory.for_slots([first, second, third])
    assert_equal "outside", results[first.id][:current]["status"]
    assert_equal [:entered, nil], results[second.id][:previous].values_at(:transition, :change)
    assert_nil results[third.id][:previous]
    assert_equal :baseline, results[third.id][:baseline][:transition]

    other = create_site(Workspace.create!(name: "Other workspace"))
    assert_empty Tracking::Dashboard.rows(site: other, date: third.day, device: "desktop", include_placement: true)
  end

  test "backfill only augments scope-checked saved results and is repeatable" do
    day = Date.yesterday
    saved = travel_to(day.noon) do
      series = Tracking::Enrollment.call(site: @site, phrase: "heating repair", devices: ["desktop"]).tracking_series.sole
      record(series, winner: 3, absolute: false, reference: "saved-task")
    end
    saved.daily_slot.update!(task_id: "saved-task")
    assert_nil saved.evidence["google_placement"]
    original = saved.attributes.except("updated_at", "evidence")
    provider = Object.new
    response = {reference: "saved-task", captured_at: saved.captured_at, items: organic_items(winner: 2)}
    provider.define_singleton_method(:poll) { |_slot| response }
    args = {site: @site, from: day, through: day, provider:}
    assert_equal({unverified_profile: 1}, Tracking::PlacementBackfill.call(**args))
    @site.source_snapshots.create!(provider: "Local Falcon", external_id: "0123456789abcde", observed_on: day, title: "Saved Maps scan",
      keyword: "heating repair", scope: "Google Maps", metrics: {"grid_size" => 1},
      map_grid: {"place_id" => @profile.place_id, "report_key" => "0123456789abcde", "grid_size" => 1,
        "date" => day.iso8601, "keyword" => "heating repair", "points" => [{"lat" => 53.9, "lng" => -1.1, "rank" => 1}]})
    assert_equal({unmatched: 1}, Tracking::PlacementBackfill.call(**args))
    response[:items] = organic_items(winner: 3)
    assert_equal({saved: 1}, Tracking::PlacementBackfill.call(**args))
    assert_equal 7, saved.reload.evidence.dig("google_placement", "position")
    assert_equal original, saved.attributes.except("updated_at", "evidence")
    assert_empty Tracking::PlacementBackfill.call(**args)
  end

  private

  def create_site(workspace)
    workspace.sites.create!(name: "Example", host: "example.test", language: "en", location: "York",
      time_zone: "UTC", tracking_mode: "dataforseo", rank_location_verified_at: Time.current,
      rank_location_name: "York", rank_location_code: 123, rank_country_code: "GB")
  end

  def organic_items(rows: 30, winner: nil, absolute: true)
    (1..rows).map do |rank|
      {"type" => "organic", "rank_group" => rank, "rank_absolute" => (rank + 4 if absolute),
        "url" => rank == winner ? "https://example.test/winner" : "https://competitor.test/#{rank}"}
    end
  end

  def listing(cid, absolute)
    {"type" => "local_pack", "cid" => cid, "rank_absolute" => absolute}
  end

  def record(series, rows: 30, winner: nil, additions: [], absolute: true, reference: nil)
    Tracking::RecordResult.call(series:, captured_at: Time.current,
      items: additions + organic_items(rows:, winner:, absolute:), reference:)
  end
end
