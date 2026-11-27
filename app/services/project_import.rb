class ProjectImport
  class Error < ArgumentError; end

  EVIDENCE_FIELDS = %w[provider external_id title observed_on scope metrics source_url source_path keyword].freeze
  TASK_FIELDS = %w[external_id title status priority summary source_path].freeze
  REQUIRED_EVIDENCE = %w[provider external_id title observed_on scope metrics].freeze
  REQUIRED_TASK = %w[external_id title status priority].freeze

  def self.call(site:, evidence: [], tasks: [])
    site.with_lock(requires_new: true) do
      {
        evidence: import_rows(SourceSnapshot.where(site_id: site.id), evidence, EVIDENCE_FIELDS, REQUIRED_EVIDENCE, %w[provider external_id]),
        tasks: import_rows(ProjectTask.where(site_id: site.id), tasks, TASK_FIELDS, REQUIRED_TASK, %w[external_id])
      }
    end
  end

  def self.import_rows(scope, rows, fields, required, identity)
    raise Error, "Expected an array of records" unless rows.is_a?(Array)
    totals = { created: 0, updated: 0, unchanged: 0 }
    seen = {}
    rows.each_with_index do |entry, index|
      raise Error, "Expected an object" unless entry.is_a?(Hash)
      values = entry.stringify_keys
      raise Error, "Unexpected fields: #{(values.keys - fields).join(', ')}" if (values.keys - fields).any?
      raise Error, "Missing fields: #{(required - values.keys).join(', ')}" if (required - values.keys).any?
      normalize!(values)
      if values["provider"] == SeoWorkflows::EvidenceImport::PROVIDER
        raise Error, "Use SEO tasks to import workflow evidence"
      end
      key = values.slice(*identity)
      raise Error, "Duplicate identifier within this file" if seen[key]
      seen[key] = true
      record = scope.find_or_initialize_by(key)
      record.assign_attributes(values)
      outcome = record.new_record? ? :created : (record.changed? ? :updated : :unchanged)
      record.save! unless outcome == :unchanged
      totals[outcome] += 1
    rescue ActiveRecord::RecordInvalid, Error, Date::Error => e
      raise Error, "#{scope.klass.model_name.human}, row #{index + 1}: #{e.message}"
    end
    totals
  end

  def self.normalize!(values)
    values.each do |key, value|
      next if key == "metrics"
      if key == "observed_on"
        next if value.instance_of?(Date)
        raise Error, "Use an ISO calendar date" unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        values[key] = Date.iso8601(value)
      else
        raise Error, "#{key} must contain text" unless value.nil? || value.is_a?(String)
        values[key] = value&.strip.presence
      end
    end
    path = values["source_path"]
    if path && (path.start_with?("/", "~", "\\") || path.match?(%r{\A[A-Za-z]:|(?:\A|[/\\])\.\.(?:[/\\]|\z)|[[:cntrl:]]}))
      raise Error, "Source path must be a relative project reference"
    end
  end
  private_class_method :import_rows, :normalize!
end
