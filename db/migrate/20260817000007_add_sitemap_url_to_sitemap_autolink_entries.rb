# frozen_string_literal: true

# Which sitemap listed a URL was never recorded: `source` only ever held
# "sitemap" or "manual", and the removal sweep keys off that exact
# value, so it cannot carry this. A site that feeds the plugin several
# sitemaps had no way to look at one of them.
#
# Existing rows stay NULL until a sync sees their URL again and fills it
# in.
class AddSitemapUrlToSitemapAutolinkEntries < ActiveRecord::Migration[8.0]
  def change
    add_column :sitemap_autolink_entries, :sitemap_url, :string
    add_index :sitemap_autolink_entries, :sitemap_url
  end
end
