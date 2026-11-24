class SourceSnapshotsController < ApplicationController
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
  end
end
