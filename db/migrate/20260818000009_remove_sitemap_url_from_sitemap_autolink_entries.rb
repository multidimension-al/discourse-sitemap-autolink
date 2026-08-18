# frozen_string_literal: true

# Superseded by sitemap_autolink_entry_sitemaps, which can hold the
# several sitemaps one URL may be listed in. The previous migration
# copied every value across before this drops the column.
class RemoveSitemapUrlFromSitemapAutolinkEntries < ActiveRecord::Migration[8.0]
  def up
    remove_column :sitemap_autolink_entries, :sitemap_url
  end

  def down
    add_column :sitemap_autolink_entries, :sitemap_url, :string
    add_index :sitemap_autolink_entries, :sitemap_url
  end
end
