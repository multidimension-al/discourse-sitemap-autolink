# frozen_string_literal: true

# One matching phrase for an entry. Generated terms flow through review
# states; manual terms are admin-authored and always outrank generated
# ones at match time.
class SitemapAutolinkTerm < ActiveRecord::Base
  belongs_to :entry, class_name: "SitemapAutolinkEntry", foreign_key: :entry_id

  enum :state, { auto_active: 0, pending_review: 1, approved: 2, disabled: 3 }
  enum :origin, { generated: 0, manual: 1 }

  # The states that compile into linking rules.
  LINKABLE_STATES = %w[auto_active approved].freeze

  # `pluck` of a string SQL fragment ("table.state") can hand back the
  # stored integer instead of the enum's name, depending on how the
  # select is written; resolve either form to the name.
  def self.state_name(value)
    states.key(value) || value.to_s
  end

  validates :phrase, presence: true
  validates :normalized_phrase,
            presence: true,
            uniqueness: {
              scope: :entry_id,
            }

  scope :linkable, -> { where(state: LINKABLE_STATES) }

  before_validation do
    if phrase.present?
      self.normalized_phrase = SitemapAutolink::Matcher.normalize(phrase.to_s)
    end
  end
end
