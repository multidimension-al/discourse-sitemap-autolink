# frozen_string_literal: true

# Audit record of one sitemap synchronization run: when it ran, which
# sources it fetched, what changed, and any errors. This is the durable
# proof of what the sync did, browsable from the admin page and API.
class SitemapAutolinkSyncRun < ActiveRecord::Base
  scope :recent, -> { order(started_at: :desc) }

  def self.record(triggered_by:)
    run = create!(started_at: Time.zone.now, triggered_by: triggered_by)
    report = yield
    run.update!(
      finished_at: Time.zone.now,
      success: report[:errors].blank?,
      urls_seen: report[:seen].to_i,
      urls_excluded: report[:excluded].to_i,
      entries_added: report[:added].size,
      entries_retitled: report[:title_changed].size,
      entries_removed: report[:removed].size,
      phrases_added: report[:phrases_added].size,
      phrases_removed: report[:phrases_removed].size,
      error_details: report[:errors].first(20).join("\n").presence,
      sources: report[:sources]&.join("\n"),
    )
    [run, report]
  rescue => e
    run&.update!(finished_at: Time.zone.now, success: false, error_details: "#{e.class}: #{e.message}")
    raise
  end
end
