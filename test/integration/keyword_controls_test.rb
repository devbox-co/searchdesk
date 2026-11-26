require "test_helper"

class KeywordControlsTest < ActionDispatch::IntegrationTest
  setup do
    user = User.create!(email: "controls@example.test", password: "reasonable-example-pass")
    workspace = Workspace.create!(name: "Controls")
    workspace.memberships.create!(user: user, role: "owner")
    @site = workspace.sites.create!(name: "Sample", host: "sample.test", location: "York")
    @keyword = Tracking::Enrollment.call(site: @site, phrase: "local repair")
    post login_path, params: {session: {email: user.email, password: "reasonable-example-pass"}}
  end

  test "pause and resume are scoped to the device and keep the original series" do
    mobile = @keyword.tracking_series.find_by!(device: "mobile")
    %w[pause resume].each do |state|
      patch keyword_path(@keyword), params: {device: "mobile", tracking: state}
      assert_redirected_to keyword_path(@keyword, device: "mobile")
      assert_equal state == "pause", mobile.reload.paused?
      assert_not @keyword.tracking_series.find_by!(device: "desktop").paused?
    end
    assert_equal 2, @keyword.tracking_series.count
    get keyword_path(@keyword, range: "all")
    assert_response :success
  end

  test "preferred page changes create a dated site assignment" do
    patch preferred_page_keyword_path(@keyword), params: {keyword: {preferred_url: "https://elsewhere.test/"}}
    assert_nil @keyword.reload.preferred_url
    patch preferred_page_keyword_path(@keyword), params: {keyword: {preferred_url: "https://sample.test/repair"}}
    assert_equal "https://sample.test/repair", @keyword.reload.preferred_page_on(Date.tomorrow)
    patch preferred_page_keyword_path(@keyword), params: {keyword: {preferred_url: ""}}
    assert_nil @keyword.reload.preferred_page_on(Date.tomorrow)
  end

  test "rankings and keyword history default to desktop and preserve an explicit mobile selection" do
    day = Date.yesterday.iso8601
    get rankings_path(source: "local", day: day)
    assert_select "#ranking-devices > #local-rank-desktop:first-child[aria-current=page]"
    mobile_link = css_select("#local-rank-mobile").sole
    assert_equal rankings_path(source: "local", day: day, device: "mobile", anchor: "ranking-devices"), mobile_link["href"]
    get mobile_link["href"], headers: {"Turbo-Frame" => mobile_link["data-turbo-frame"]}
    assert_select "turbo-frame#rankings-filters[target=_top][data-turbo-action=advance][data-filter-frame=?]", @site.id.to_s do
      assert_select "#local-rank-mobile[aria-current=page]"
      assert_select "input[name=day][value=?]", day
      assert_select "#ranking-source-gsc[data-turbo-frame=rankings-filters][href=?]", rankings_path(source: "gsc", device: "mobile", anchor: "ranking-sources")
      assert_select ".rank-term a[href=?]", keyword_path(@keyword, device: "mobile")
    end

    get keyword_path(@keyword, range: "all", before: day)
    assert_select "#keyword-devices > #keyword-rank-desktop:first-child[aria-current=page]"
    mobile_link = css_select("#keyword-rank-mobile").sole
    assert_equal keyword_path(@keyword, device: "mobile", range: "all", before: day, anchor: "keyword-devices"), mobile_link["href"]
    get mobile_link["href"], headers: {"Turbo-Frame" => mobile_link["data-turbo-frame"]}
    assert_select "turbo-frame#keyword-filters[target=_top][data-turbo-action=advance][data-filter-frame=?]", @site.id.to_s do
      assert_select "#keyword-rank-mobile[aria-current=page]"
      assert_select "#keyword-range-all[aria-current=page]"
      assert_select "#keyword-range-7[data-turbo-frame=keyword-filters][href=?]", keyword_path(@keyword, device: "mobile", range: "7", anchor: "keyword-periods")
      assert_select "input[name=device][value=mobile]"
    end
  end
end
