require "test_helper"

class WorkspaceAuthenticationTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  PASSWORD = "A long test password 702!"

  test "new account starts with a private empty workspace and can onboard a manual site" do
    get dashboard_path
    assert_redirected_to login_path

    assert_difference("User.count", 1) do
      post signup_path, params: { user: { email: " Owner@Example.org ", password: PASSWORD, password_confirmation: PASSWORD } }
    end
    assert_redirected_to onboarding_path
    user = User.find_by!(email: "owner@example.org")
    assert user.memberships.sole.owner?
    assert_empty user.workspaces.sole.sites

    post onboarding_path, params: { site: site_attributes(host: "https://Shop.Example.org/") }
    assert_redirected_to dashboard_path
    site = user.workspaces.sole.sites.sole
    assert_equal "shop.example.org", site.host
    assert_empty site.keywords

    delete logout_path
    get dashboard_path
    assert_redirected_to login_path
    post login_path, params: { session: { email: "OWNER@example.org", password: PASSWORD } }
    assert_redirected_to dashboard_path
  end

  test "site selection and workspace mutations require membership in the active workspace" do
    owner = person("owner")
    intruder = person("outsider")
    site = owner.workspaces.sole.sites.create!(site_attributes(host: "private.example.org"))
    role = owner.workspaces.sole.memberships.sole
    sign_in(intruder)

    post select_site_path(site)
    assert_response :not_found
    assert_no_difference("Membership.count") do
      delete workspace_member_path(role)
    end
    assert_response :not_found
  end

  test "only owners can grant access, an unverified address cannot receive access, and revocation is immediate" do
    owner = person("owner")
    viewer = person("viewer")
    site = owner.workspaces.sole.sites.create!(site_attributes)
    sign_in(owner)

    assert_no_difference("Membership.count") do
      post workspace_members_path, params: { membership: { email: viewer.email, role: "viewer" } }
    end

    viewer.update!(email_verified_at: Time.current)
    assert_difference("Membership.count", 1) do
      post workspace_members_path, params: { membership: { email: viewer.email, role: "viewer" } }
    end
    grant = owner.workspaces.sole.memberships.find_by!(user: viewer)
    sign_in(viewer)
    post select_site_path(site)
    assert_redirected_to dashboard_path
    post onboarding_path, params: { site: site_attributes(host: "no.example.org") }
    assert_response :forbidden
    patch workspace_member_path(grant), params: { membership: { role: "manager" } }
    assert_response :forbidden
    assert_equal "viewer", grant.reload.role

    other = open_session
    other.post login_path, params: { session: { email: owner.email, password: PASSWORD } }
    other.patch workspace_member_path(grant), params: { membership: { role: "manager" } }
    assert_equal "manager", grant.reload.role
    assert_difference("Site.count", 1) do
      post onboarding_path, params: { site: site_attributes(host: "added.example.org") }
    end
    other.delete workspace_member_path(grant)
    assert_no_difference("Site.count") do
      post onboarding_path, params: { site: site_attributes(host: "stale.example.org") }
    end
    assert_response :forbidden
    post select_site_path(site)
    assert_response :not_found
  end

  test "password reset is single use, expires and signs out previously issued sessions" do
    user = person("recovery")
    sign_in(user)
    user.workspaces.sole.sites.create!(site_attributes)
    token = user.password_reset_token
    other = open_session
    other.patch password_reset_path(token), params: { user: { password: "Changed test password 090!", password_confirmation: "Changed test password 090!" } }
    assert_equal "/login", URI(other.response.location).path
    assert_nil User.find_by_password_reset_token(token)
    get dashboard_path
    assert_redirected_to login_path
    other.get edit_password_reset_path(token)
    assert_equal "/password_resets/new", URI(other.response.location).path
    fresh_token = user.reload.password_reset_token
    travel 21.minutes do
      assert_nil User.find_by_password_reset_token(fresh_token)
    end
  end

  test "signing out revokes only the current browser and expired sessions cannot open a workspace" do
    user = person("sessions")
    user.workspaces.sole.sites.create!(site_attributes)
    sign_in(user)
    other = open_session
    other.post login_path, params: { session: { email: user.email, password: PASSWORD } }
    assert_equal 2, user.login_sessions.count

    delete logout_path
    assert_equal 1, user.login_sessions.count
    other.get dashboard_path
    assert_equal 200, other.response.status
    user.login_sessions.sole.update!(expires_at: 1.minute.ago)
    other.get dashboard_path
    assert_equal "/login", URI(other.response.location).path
  end

  test "both reset requests receive the same response and instructions use the trusted application host" do
    user = person("mail")
    assert_enqueued_emails = ->(email, count) do
      assert_enqueued_jobs(count, only: ActionMailer::MailDeliveryJob) do
        post password_resets_path, params: { password_reset: { email: email } }
      end
      assert_redirected_to login_path
      flash[:notice]
    end
    assert_equal assert_enqueued_emails.call(user.email, 1), assert_enqueued_emails.call("unknown@example.org", 0)
    mail = PasswordResetMailer.instructions(user)
    assert_equal [user.email], mail.to
    assert_includes mail.body.encoded, "/password_resets/"
  end

  test "verification link must belong to the signed-in account and is invalid after use" do
    user = person("recipient")
    sign_in(person("another"))
    token = user.generate_token_for(:email_verification)
    get verify_email_path(token)
    assert_redirected_to new_email_verification_path
    assert_nil user.reload.email_verified_at

    sign_in(user)
    get verify_email_path(token)
    assert_response :success
    assert_nil user.reload.email_verified_at
    post verify_email_path(token)
    assert_redirected_to dashboard_path
    assert user.reload.email_verified_at
    assert_nil User.find_by_token_for(:email_verification, token)
  end

  test "production authenticity protection permits the genuine site creation form" do
    sign_in(person("form-user"))
    original_setting = OnboardingController.allow_forgery_protection
    OnboardingController.allow_forgery_protection = true

    assert_no_difference("Site.count") do
      post onboarding_path, params: { site: site_attributes }
    end
    assert_response :unprocessable_entity

    get onboarding_path
    assert_response :success
    token = css_select('form[action="/onboarding"] input[name="authenticity_token"]').first&.[]("value")
    assert token.present?, "The onboarding form should carry a Rails authenticity token"
    assert_difference("Site.count", 1) do
      post onboarding_path, params: { authenticity_token: token, site: site_attributes }
    end
    assert_redirected_to dashboard_path
  ensure
    OnboardingController.allow_forgery_protection = original_setting
  end

  test "switching sites requires an already open form to be refreshed" do
    user = person("two-tabs")
    sites = %w[first second].map { |host| user.workspaces.sole.sites.create!(site_attributes(host: "#{host}.example.org")) }
    sign_in(user)
    post select_site_path(sites.first)
    original_setting = OnboardingController.allow_forgery_protection
    OnboardingController.allow_forgery_protection = true
    get onboarding_path
    token = css_select('form[action="/onboarding"] input[name="authenticity_token"]').first["value"]
    post select_site_path(sites.last)
    assert_no_difference("Site.count") do
      post onboarding_path, params: { authenticity_token: token, site: site_attributes }
    end
    assert_response :unprocessable_entity
  ensure
    OnboardingController.allow_forgery_protection = original_setting
  end

  test "explicit demo mode seeds independent synthetic history" do
    users = [person("demo1"), person("demo2")]
    users.each do |user|
      sign_in(user)
      post onboarding_path, params: { site: { tracking_mode: "demo" } }
      assert_redirected_to dashboard_path
    end
    first, second = users.map { |user| user.workspaces.sole.sites.sole }
    assert_equal "northline.example", first.host
    assert_equal first.host, second.host
    assert_equal 5, first.keywords.count
    assert_equal 5, second.keywords.count
    assert_empty first.keywords.ids & second.keywords.ids
    today = Time.current.in_time_zone(first.time_zone).to_date
    rows = Tracking::Dashboard.rows(site: first, date: today, device: "mobile")
    assert_equal({
      "boiler servicing basingstoke" => [:up, 6], "boiler repair basingstoke" => [:down, -6],
      "heating engineer basingstoke" => [:unchanged, 0], "radiator repair basingstoke" => [:entered, nil],
      "heat pump installation basingstoke" => [:up, 3]
    }, rows.to_h { |row| [row[:keyword].phrase, [row[:transition], row[:change]]] })
  end

  test "an unconfigured rank provider holds managed onboarding without creating a site" do
    previous = ENV["DATAFORSEO_ENABLED"]
    ENV["DATAFORSEO_ENABLED"] = "false"
    sign_in(person("managed-onboarding"))
    assert_no_difference("Site.count") do
      post onboarding_path, params: { site: site_attributes.merge(tracking_mode: "dataforseo", rank_country_code: "us") }
    end
    assert_response :unprocessable_entity
    assert_select "input[name=?][value=?]", "site[rank_country_code]", "US"
    assert_match(/Managed tracking is not configured/, response.body)
  ensure
    ENV["DATAFORSEO_ENABLED"] = previous
  end

  private

  def person(slug)
    user = User.create!(email: "#{slug}@example.org", password: PASSWORD)
    Workspace.create!(name: "#{slug} workspace").memberships.create!(user: user, role: "owner")
    user
  end

  def sign_in(user)
    post login_path, params: { session: { email: user.email, password: PASSWORD } }
    assert_redirected_to dashboard_path
  end

  def site_attributes(host: "example.org")
    { name: "Example Studio", host: host, location: "Leeds", tracking_mode: "manual" }
  end
end
