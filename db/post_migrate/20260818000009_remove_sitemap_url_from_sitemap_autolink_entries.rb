# frozen_string_literal: true

# Superseded by sitemap_autolink_entry_sitemaps, which can hold the
# several sitemaps one URL may be listed in. The previous migration
# copied every value across before this drops the column.
#
# A post-deployment migration because Discourse refuses column drops in
# a regular one: during a rolling deploy the old code is still running
# and would select a column that had vanished under it. The model
# ignores the column from this commit onward, so by the time this runs
# nothing has read it for a full deploy.
class RemoveSitemapUrlFromSitemapAutolinkEntries < ActiveRecord::Migration[8.0]
  def up
    remove_column :sitemap_autolink_entries, :sitemap_url
  end

  def down
    add_column :sitemap_autolink_entries, :sitemap_url, :string
    add_index :sitemap_autolink_entries, :sitemap_url
  end
end
