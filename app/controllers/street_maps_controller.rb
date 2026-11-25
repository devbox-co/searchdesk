class StreetMapsController < ApplicationController
  def show
    no_store
    today = Time.current.in_time_zone(current_site.time_zone).to_date
    snapshot = LocalFalcon::MapsSummary.scan_scope(current_site).where(observed_on: ..today).find(params[:id])
    return head :not_found unless LocalFalcon::ScanGrid.new(snapshot).street_map_url

    png = LocalFalcon::StreetMapImage.fetch(snapshot)
    return send_data(png, type: "image/png", disposition: "inline", filename: "street-map.png") if png

    response.set_header("Retry-After", LocalFalcon::StreetMapImage::RETRY_DELAY.to_i.to_s)
    head :service_unavailable
  end
end
