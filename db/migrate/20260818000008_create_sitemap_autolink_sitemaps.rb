# frozen_string_literal: true

# Sitemaps become records the admin manages, not just a setting string.
#
# Two things forced this. First, "which sitemap did this URL come from"
# is not a single value: the same URL legitimately appears in more than
# one sitemap file, so it needs a join, not a column. Second, a
# <sitemapindex> used to expand and import EVERY child silently — an
# index whose children hold tens of thousands of URLs turned one setting
# line into an unwanted import with no way to see it coming, let alone
# decline it. Children are now recorded first and imported only once
# somebody says so.
class CreateSitemapAutolinkSitemaps < ActiveRecord::Migration[8.0]
  def up
    create_table :sitemap_autolink_sitemaps do |t|
      t.string :url, null: false
      # The index that listed this sitemap; NULL for a configured source.
      t.string :parent_url
      t.string :content_type, null: false, default: "content"
      # index | urlset | unknown (unknown until it has been fetched once)
      t.string :kind, null: false, default: "unknown"
      # enabled | pending | ignored
      t.string :status, null: false, default: "pending"
      t.boolean :configured, null: false, default: false
      t.integer :url_count, null: false, default: 0
      # A sitemap larger than the fetch cap is counted from a truncated
      # document, so its count is a floor ("43,000+"), not a total.
      t.boolean :url_count_partial, null: false, default: false
      t.datetime :last_seen_at
      t.datetime :last_fetched_at
      t.string :last_error
      t.timestamps
    end
    add_index :sitemap_autolink_sitemaps, :url, unique: true
    add_index :sitemap_autolink_sitemaps, :status
    add_index :sitemap_autolink_sitemaps, :parent_url

    create_table :sitemap_autolink_entry_sitemaps do |t|
      t.bigint :entry_id, null: false
      t.bigint :sitemap_id, null: false
      t.datetime :last_seen_at
      t.timestamps
    end
    add_index :sitemap_autolink_entry_sitemaps, %i[entry_id sitemap_id], unique: true
    add_index :sitemap_autolink_entry_sitemaps, :sitemap_id

    # Whatever a sync already imported is, by definition, a sitemap the
    # admin was importing from — so it is carried over as `enabled`.
    # Only genuinely new children arrive as `pending`, which keeps the
    # opt-in from retroactively switching off a working install.
    execute <<~SQL
      INSERT INTO sitemap_autolink_sitemaps
        (url, content_type, kind, status, configured, url_count,
         url_count_partial, created_at, updated_at)
      SELECT e.sitemap_url, MIN(e.content_type), 'urlset', 'enabled', false, 0,
             false, NOW(), NOW()
      FROM sitemap_autolink_entries e
      WHERE e.sitemap_url IS NOT NULL AND e.sitemap_url <> ''
      GROUP BY e.sitemap_url
    SQL

    execute <<~SQL
      INSERT INTO sitemap_autolink_entry_sitemaps
        (entry_id, sitemap_id, last_seen_at, created_at, updated_at)
      SELECT e.id, s.id, e.last_seen_at, NOW(), NOW()
      FROM sitemap_autolink_entries e
      JOIN sitemap_autolink_sitemaps s ON s.url = e.sitemap_url
      WHERE e.sitemap_url IS NOT NULL AND e.sitemap_url <> ''
    SQL
  end

  def down
    drop_table :sitemap_autolink_entry_sitemaps
    drop_table :sitemap_autolink_sitemaps
  end
end
