class WordingSetting < ApplicationRecord
  belongs_to :site
  self.filter_attributes += [:phrases]
  has_many :wording_runs, dependent: :delete_all
  before_validation { self.revision ||= SecureRandom.uuid }
  validate :validate_phrases, if: :enabled?

  # Restrict the proposed provider payload before recording consent.
  CONTACT_PATTERN = %r{@|(?:[a-z][a-z0-9+.-]*://)|(?:\b(?:mailto|tel):)|(?:\b(?:[a-z0-9-]+\.)+[a-z]{2,63}\b)|(?:\d[\d\s().+-]{5,}\d)}i
  CONTROL_PATTERN = /[[:cntrl:]<>]/

  normalizes :phrases, with: ->(value) { value.to_s.lines.map(&:strip).reject(&:blank?).join("\n") }

  def lines
    phrases.to_s.lines.map(&:strip).reject(&:blank?)
  end

  def selected_line
    return unless enabled?
    run = wording_runs.find_by(revision: revision, status: "selected")
    lines.fetch(run.choice - 1) if run&.choice&.between?(1, lines.length)
  end

  private

  def validate_phrases
    return errors.add(:phrases, "must use 1,000 characters or fewer") if phrases.to_s.size > 1_000
    candidates = lines
    unless candidates.size.between?(1, 6) && candidates.uniq.size == candidates.size
      errors.add(:phrases, "must include one to six distinct lines")
    end
    errors.add(:phrases, "must use 160 characters or fewer per line") if candidates.any? { |line| line.size > 160 }
    errors.add(:phrases, "must exclude contact details and links") if candidates.any? { |line| line.match?(CONTACT_PATTERN) }
    errors.add(:phrases, "must contain plain text") if candidates.any? { |line| line.match?(CONTROL_PATTERN) }
  end
end
