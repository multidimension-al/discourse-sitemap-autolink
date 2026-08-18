# frozen_string_literal: true

# Which sitemaps list a URL. A join rather than a column on the entry
# because the same URL is routinely listed in more than one sitemap —
# a section sitemap and a "recently updated" one, or two overlapping
# shards — and an admin filtering by either of them must find it under
# both.
class SitemapAutolinkEntrySitemap < ActiveRecord::Base
  self.table_name = "sitemap_autolink_entry_sitemaps"

  belongs_to :entry, class_name: "SitemapAutolinkEntry", foreign_key: :entry_id
  belongs_to :sitemap, class_name: "SitemapAutolinkSitemap", foreign_key: :sitemap_id

  # Uniqueness is the database's job here (a unique index on the pair).
  # A model validation would add a SELECT to every membership write, and
  # a sync writes one per URL per sitemap.
end
