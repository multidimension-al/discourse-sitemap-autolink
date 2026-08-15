# frozen_string_literal: true

class CreateSitemapAutolinkSyncRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :sitemap_autolink_sync_runs do |t|
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.boolean :success, null: false, default: false
      t.string :triggered_by, null: false, default: "schedule"
      t.integer :urls_seen, null: false, default: 0
      t.integer :urls_excluded, null: false, default: 0
      t.integer :entries_added, null: false, default: 0
      t.integer :entries_retitled, null: false, default: 0
      t.integer :entries_removed, null: false, default: 0
      t.integer :phrases_added, null: false, default: 0
      t.integer :phrases_removed, null: false, default: 0
      t.text :error_details
      t.text :sources
      t.timestamps
    end
    add_index :sitemap_autolink_sync_runs, :started_at
  end
end
