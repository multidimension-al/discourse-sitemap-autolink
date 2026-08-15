# frozen_string_literal: true

# One canonical GBFans destination (product, shop category, wiki article,
# …) that may be auto-linked from posts.
class GbfansAutolinkEntry < ActiveRecord::Base
  has_many :terms,
           class_name: "GbfansAutolinkTerm",
           foreign_key: :entry_id,
           dependent: :destroy

  validates :url, presence: true, uniqueness: true
  validates :title, presence: true
  validates :content_type, presence: true

  scope :active, -> { where(enabled: true, removed_from_source: false) }

  def self.normalize_url(url)
    url.to_s.strip.sub(%r{/+\z}, "")
  end
end
