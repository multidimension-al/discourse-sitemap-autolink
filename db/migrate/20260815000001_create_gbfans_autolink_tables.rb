# frozen_string_literal: true

class CreateGbfansAutolinkTables < ActiveRecord::Migration[8.0]
  def change
    create_table :gbfans_autolink_entries do |t|
      t.string :url, null: false
      t.string :title, null: false
      t.string :content_type, null: false
      t.string :source
      t.string :title_source, null: false, default: "page"
      t.integer :priority
      t.boolean :enabled, null: false, default: true
      t.boolean :auto_discovered, null: false, default: true
      t.boolean :removed_from_source, null: false, default: false
      t.string :lastmod
      t.datetime :first_seen_at
      t.datetime :last_seen_at
      t.timestamps
    end
    add_index :gbfans_autolink_entries, :url, unique: true
    add_index :gbfans_autolink_entries, :content_type
    add_index :gbfans_autolink_entries, %i[enabled removed_from_source]

    create_table :gbfans_autolink_terms do |t|
      t.integer :entry_id, null: false
      t.string :phrase, null: false
      t.string :normalized_phrase, null: false
      t.integer :state, null: false, default: 0
      t.integer :origin, null: false, default: 0
      t.string :review_reason
      t.timestamps
    end
    add_index :gbfans_autolink_terms, %i[entry_id normalized_phrase], unique: true
    add_index :gbfans_autolink_terms, :normalized_phrase
    add_index :gbfans_autolink_terms, :state
  end
end
