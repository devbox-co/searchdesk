class OnboardingController < ApplicationController
  skip_before_action :require_site, only: %i[new create]
  before_action :require_site_manager

  def new
    @site = current_workspace.sites.build
  end

  def show
    @first_keyword = current_site.keywords.order(:id).first
  end

  def finish
    return head :forbidden unless params[:site_id].to_s == current_site.id.to_s

    current_site.update!(setup_tour_pending: false)
    redirect_to dashboard_path, status: :see_other
  end

  def create
    attributes = params.require(:site).permit(:name, :host, :location, :language, :time_zone, :tracking_mode)
    if attributes[:tracking_mode] == "demo"
      DemoSiteSetup::DEFAULTS.each do |key, default|
        attributes[key] = default if attributes[key].blank?
      end
    end
    @site = current_workspace.sites.build(attributes)
    @rank_country_code = params.dig(:site, :rank_country_code).to_s.strip.upcase
    if @rank_country_code.present? && !SearchConsole::DailyPositions::COUNTRIES.key?(@rank_country_code)
      @site.errors.add(:rank_country_code, "must be a two-letter ISO country code")
      return render :new, status: :unprocessable_entity
    end
    @site.rank_country_code = @rank_country_code.presence
    if @site.tracking_mode == "dataforseo"
      unless Tracking::DataForSeo.enabled?
        @site.errors.add(:base, "Managed tracking is not configured. Choose manual imports or ask your administrator to connect the rank provider.")
        return render :new, status: :unprocessable_entity
      end
      resolved = Tracking::LocationResolver.resolve!(name: @site.location, country: @rank_country_code,
        expected_code: params.dig(:site, :rank_location_code).presence)
      @site.assign_attributes(resolved)
    end
    current_workspace.with_lock do
      @site.setup_tour_pending = @site.tracking_mode != "demo" &&
        !current_workspace.sites.where.not(tracking_mode: "demo").exists?
      @site.save!
      DemoSiteSetup.call(@site) if @site.tracking_mode == "demo"
    end
    select_current_site(@site)
    redirect_to(@site.setup_tour_pending? ? setup_guide_path : dashboard_path, notice: "Your site is ready.")
  rescue ActiveRecord::RecordInvalid => error
    @site.errors.add(:base, error.record.errors.full_messages.to_sentence) unless error.record == @site
    render :new, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotUnique
    @site.errors.add(:host, "has already been added to this workspace")
    render :new, status: :unprocessable_entity
  rescue Tracking::LocationResolver::Error => error
    @site.errors.add(:location, error.message)
    render :new, status: :unprocessable_entity
  end
end
