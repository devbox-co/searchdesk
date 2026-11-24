class RankImportsController < ApplicationController
  before_action :require_site_manager
  before_action :load_keyword
  MAX_BYTES = 256.kilobytes

  def new
  end

  def create
    values = params.require(:rank_import).permit(:device, :file, :payload)
    series = @keyword.tracking_series.current.find_by!(device: values[:device])
    upload = values[:file]
    payload = upload.respond_to?(:read) ? upload.read(MAX_BYTES + 1) : values[:payload].to_s
    if payload.bytesize > MAX_BYTES || payload.blank?
      @error = "Provide one JSON observation of up to 256 KiB."
      return render :new, status: :unprocessable_entity
    end
    Tracking::ManualImport.call(series: series, payload: payload)
    redirect_to keyword_path(@keyword, device: series.device), notice: "Observation imported."
  rescue ArgumentError, ActiveRecord::RecordInvalid, JSON::ParserError => e
    @error = e.message
    render :new, status: :unprocessable_entity
  end

  private

  def load_keyword
    @keyword = current_site.keywords.find(params[:keyword_id])
    head :forbidden unless current_site.tracking_mode == "manual"
  end
end
