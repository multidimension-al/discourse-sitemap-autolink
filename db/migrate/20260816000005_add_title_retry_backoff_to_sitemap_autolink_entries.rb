# frozen_string_literal: true

class AddTitleRetryBackoffToSitemapAutolinkEntries < ActiveRecord::Migration[8.0]
  def change
    add_column :sitemap_autolink_entries, :title_fetch_failures, :integer, default: 0, null: false
    add_column :sitemap_autolink_entries, :next_title_fetch_at, :datetime
  end
end
