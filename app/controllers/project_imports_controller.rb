class ProjectImportsController < ApplicationController
  before_action :require_site_manager
  MAX_BYTES = 8.megabytes

  def new
  end

  def create
    upload = params.dig(:project_import, :file)
    raise ProjectImport::Error, "Choose a JSON file" unless upload.respond_to?(:read)
    contents = upload.read(MAX_BYTES + 1)
    raise ProjectImport::Error, "The file exceeds 8 MiB" if contents.bytesize > MAX_BYTES
    package = JSON.parse(contents)
    unless package.is_a?(Hash) && package.any? && (package.keys - %w[evidence tasks]).empty?
      raise ProjectImport::Error, "Use a JSON object with evidence or tasks arrays"
    end
    totals = ProjectImport.call(site: current_site, evidence: package.fetch("evidence", []), tasks: package.fetch("tasks", []))
    counts = totals.map { |type, n| "#{type.to_s.capitalize}: #{n[:created]} added, #{n[:updated]} updated, #{n[:unchanged]} unchanged" }
    redirect_to new_project_import_path, notice: counts.join(". ") + "."
  rescue JSON::ParserError
    @error = "The file could not be read as JSON."
    render :new, status: :unprocessable_entity
  rescue ProjectImport::Error => e
    @error = e.message
    render :new, status: :unprocessable_entity
  end
end
