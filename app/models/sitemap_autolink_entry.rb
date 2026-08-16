# frozen_string_literal: true

# One canonical destination (product page, wiki article, documentation
# page, …) that may be auto-linked from posts. URLs are stored as they
# appear in the sitemap (absolute); manually created entries may use
# forum-relative URLs.
class SitemapAutolinkEntry < ActiveRecord::Base
  has_many :terms,
           class_name: "SitemapAutolinkTerm",
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
