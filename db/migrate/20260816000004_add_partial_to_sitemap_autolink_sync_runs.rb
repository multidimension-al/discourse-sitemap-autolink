# frozen_string_literal: true

class AddPartialToSitemapAutolinkSyncRuns < ActiveRecord::Migration[8.0]
  def change
    add_column :sitemap_autolink_sync_runs, :partial, :boolean, default: false, null: false
  end
end
