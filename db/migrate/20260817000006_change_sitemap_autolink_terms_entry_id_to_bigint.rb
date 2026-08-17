# frozen_string_literal: true

# `entry_id` was declared as a 4-byte integer while the entries it
# references have bigint primary keys. Any forum whose id sequences have
# passed 2^31 — which Discourse's own test suite simulates deliberately
# — cannot store a term at all: every insert raises
# ActiveModel::RangeError. The column has to be as wide as the key it
# points at.
class ChangeSitemapAutolinkTermsEntryIdToBigint < ActiveRecord::Migration[8.0]
  def up
    change_column :sitemap_autolink_terms, :entry_id, :bigint
  end

  def down
    change_column :sitemap_autolink_terms, :entry_id, :integer
  end
end
