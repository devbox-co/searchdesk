class SourceSnapshotsController < ApplicationController
  before_action :require_workspace_owner, only: :geogrid

  def geogrid
    entry = LocalFalcon::GeogridExport.entry(LocalFalcon::GeogridExport.scope(current_site).find(params[:id]))
    raise ActiveRecord::RecordNotFound unless entry

    response.headers["Cache-Control"] = "no-store"
    send_data LocalFalcon::GeogridExport.csv(entry), type: "text/csv",
      filename: "searchdesk-geogrid-#{entry.fetch('reference')}.csv", disposition: "attachment"
  end

  def index
    all = SourceSnapshot.visible_for(current_site)
    @imports_only = params[:origin] == "imported"
    all = all.catalogue_imports if @imports_only
    @providers = all.distinct.order(:provider).pluck(:provider)
    rows = all.order(observed_on: :desc, id: :desc)
    rows = rows.where(provider: params[:provider]) if params[:provider].present?
    rows = rows.where("LOWER(keyword) = ?", params[:keyword].to_s.strip.downcase) if params[:keyword].present?
    if params[:q].present?
      match = "%#{SourceSnapshot.sanitize_sql_like(params[:q].to_s.strip)}%"
      rows = rows.where("title ILIKE ? OR scope ILIKE ? OR external_id ILIKE ?", match, match, match)
    end
    @page = params[:page].to_s.to_i.clamp(1, 100_000)
    @records = rows.offset((@page - 1) * 50).limit(51).to_a
    @more = @records.length > 50
    @records.pop if @more
  end

  def show
    @snapshot = SourceSnapshot.visible_for(current_site).find(params[:id])
    @dedicated_lsa = @snapshot.provider == LocalSeoData::Collection::PROVIDER &&
      @snapshot.metrics["kind"] == LocalSeoData::Collection::KINDS.fetch("M4")
    @profile_monitor = [LocalSeoData::Collection::PROVIDER, LocalSeoData::DataForSeoCollection::PROVIDER].include?(@snapshot.provider) &&
      @snapshot.metrics["kind"] == LocalSeoData::Collection::KINDS.fetch("M3")
    @data_for_seo_reviews = @snapshot.provider == LocalSeoData::DataForSeoCollection::PROVIDER &&
      @snapshot.metrics["kind"] == "review_activity"
    @ai_sample = @snapshot.provider == SeoWorkflows::AiVisibilitySample::PROVIDER
    @maps_grid = LocalFalcon::GeogridExport.scope(current_site).exists?(id: @snapshot.id) &&
      LocalFalcon::ScanGrid.new(@snapshot).points.any?
    @maps_scan_request = @snapshot.provider == LocalFalcon::ScanCollection::PROVIDER
    @page_comparison = @snapshot.provider == SeoWorkflows::PageComparison::PROVIDER
    @citation_import = @snapshot.provider == SeoWorkflows::EvidenceImport::PROVIDER && @snapshot.metrics["kind"] == "citation_audit"
    raise ActiveRecord::RecordNotFound if (@dedicated_lsa || @profile_monitor || @data_for_seo_reviews || @ai_sample || @maps_scan_request || @page_comparison || @citation_import) && @snapshot.metrics["host"] != current_site.host
  end
end
