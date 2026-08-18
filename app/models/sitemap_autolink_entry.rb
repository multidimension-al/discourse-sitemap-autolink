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
  has_many :entry_sitemaps,
           class_name: "SitemapAutolinkEntrySitemap",
           foreign_key: :entry_id,
           dependent: :delete_all
  has_many :sitemaps, through: :entry_sitemaps, source: :sitemap

  validates :url, presence: true, uniqueness: true
  validates :title, presence: true
  validates :content_type, presence: true

  scope :active, -> { where(enabled: true, removed_from_source: false) }
  # Kept but no longer listed anywhere. These are the rows a purge
  # deletes outright; everything else is only ever disabled.
  scope :gone, -> { where(removed_from_source: true) }

  def self.normalize_url(url)
    url.to_s.strip.sub(%r{/+\z}, "")
  end
end
