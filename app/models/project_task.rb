class ProjectTask < ApplicationRecord
  belongs_to :site
  WORKING_STATES = %w[to_do in_progress waiting completed dismissed].freeze
  ACTIONABLE_STATES = %w[to_do open approved in_progress ready_for_review awaiting_selection needs_evidence proposed].freeze
  EFFECTIVE_STATUS = Arel.sql("COALESCE(working_status, status)")
  scope :with_current_status, ->(status) { where("COALESCE(working_status, status) IN (?)", Array(status)) }
  scope :by_priority, -> { in_order_of(Arel.sql("LOWER(priority)"), %w[critical urgent high medium low], filter: false).order(:id) }
  validates :external_id, :title, :status, :priority, presence: true
  validates :external_id, :title, :status, :priority, length: { maximum: 255 }
  validates :summary, length: { maximum: 60_000 }
  validates :source_path, length: { maximum: 4096 }
  validates :working_status, inclusion: { in: WORKING_STATES }, allow_nil: true
  validates :owner_note, length: { maximum: 10_000 }

  def effective_status
    working_status || status
  end
end
