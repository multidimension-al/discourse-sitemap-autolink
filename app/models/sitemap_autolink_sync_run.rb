# frozen_string_literal: true

# Audit record of one sitemap synchronization run: when it ran, which
# sources it fetched, what changed, and any errors. This is the durable
# proof of what the sync did, browsable from the admin page and API.
class SitemapAutolinkSyncRun < ActiveRecord::Base
  scope :recent, -> { order(started_at: :desc) }

  # An open run older than the time budget (plus slack) cannot still be
  # alive — the budget would have stopped it — so it was killed mid-run.
  # UI and sweeper both use this to call a corpse a corpse quickly.
  def self.stale_after
    (SiteSetting.sitemap_autolink_sync_time_budget_minutes + 15).minutes
  end

  # Yields the freshly created run row so the caller can stream live
  # progress into it while the sync works (the admin UI polls it).
  def self.record(triggered_by:)
    run = create!(started_at: Time.zone.now, triggered_by: triggered_by)
    report = yield run
    run.update!(
      finished_at: Time.zone.now,
      success: report[:errors].blank?,
      partial: !!report[:partial],
      urls_seen: report[:seen].to_i,
      urls_excluded: report[:excluded].to_i,
      entries_added: report[:added].size,
      entries_retitled: report[:title_changed].size,
      entries_removed: report[:removed].size,
      phrases_added: report[:phrases_added].size,
      phrases_removed: report[:phrases_removed].size,
      error_details: (report[:errors].first(20) + Array(report[:notes])).join("\n").presence,
      sources: report[:sources]&.join("\n"),
    )
    [run, report]
  rescue => e
    run&.update!(finished_at: Time.zone.now, success: false, error_details: "#{e.class}: #{e.message}")
    raise
  end
end
