# frozen_string_literal: true

module Jobs
  # Daily sitemap → catalog synchronization. Post cooking never fetches
  # anything; this job is the only place remote content is read. Every
  # run is recorded in sitemap_autolink_sync_runs as a durable audit
  # trail (visible in the admin UI and API).
  class SitemapAutolinkSync < ::Jobs::Scheduled
    every 1.day

    def execute(args)
      triggered_by = args[:triggered_by].presence || "schedule"
      return if !SiteSetting.sitemap_autolink_enabled
      return if !SiteSetting.sitemap_autolink_sync_enabled && triggered_by == "schedule"
      return if SiteSetting.sitemap_autolink_sources.blank?

      # An admin cancel suppresses queued/new syncs for its lifetime —
      # a backlog of Sync-now clicks must not revive cancelled work.
      if SitemapAutolink::SitemapSync.cancel_requested?
        Rails.logger.info("sitemap-autolink sync: skipped (#{triggered_by}) — admin cancel in effect")
        return
      end

      # Single-flight: exactly one sync at a time. Duplicate queued
      # clicks skip instead of running concurrently and contending on
      # the same entries. TTL covers the worst-case run plus slack, so
      # a killed run can never wedge future syncs.
      lock_ttl = SiteSetting.sitemap_autolink_sync_time_budget_minutes * 60 + 300
      lock_key = SitemapAutolink::SitemapSync::RUNNING_LOCK_KEY
      if !Discourse.redis.set(lock_key, Time.now.to_i.to_s, ex: lock_ttl, nx: true)
        Rails.logger.info("sitemap-autolink sync: skipped (#{triggered_by}) — another sync is already running")
        return
      end

      # A deploy/rebuild or Sidekiq restart can kill a sync mid-run
      # (shutdown interrupts bypass normal error handling), leaving its
      # audit row open with no counts and no error. Label those so they
      # don't sit in the history as unexplained failures.
      SitemapAutolinkSyncRun
        .where(finished_at: nil, error_details: nil)
        .where("started_at < ?", 2.hours.ago)
        .update_all(
          success: false,
          error_details:
            "interrupted: the server restarted mid-run (deploy/rebuild or " \
              "Sidekiq restart); the sync did not finish and recorded no counts",
        )

      begin
        _run, report =
          SitemapAutolinkSyncRun.record(triggered_by: triggered_by) do |run|
            # Mirror progress into the run row (at most every 10s) so the
            # admin page shows a climbing URL count for a Running… sync —
            # a frozen count means a stalled run, a climbing one means
            # "working, be patient".
            last_update = 0.0
            on_progress = ->(seen) do
              mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              if mono - last_update >= 10
                last_update = mono
                run.update_columns(urls_seen: seen)
              end
            end
            SitemapAutolink::SitemapSync.new(on_progress: on_progress).run!
          end

        Rails.logger.info(
          "sitemap-autolink sync (#{triggered_by}): #{report[:seen]} urls seen, " \
            "#{report[:excluded]} excluded by pattern, #{report[:added].size} added, " \
            "#{report[:title_changed].size} retitled, #{report[:removed].size} removed, " \
            "#{report[:errors].size} errors",
        )

        auto_rebake(report)
      ensure
        Discourse.redis.del(lock_key)
      end
    end

    private

    # ONE batched job per sync, never one per phrase — and none at all
    # for catalog-scale change sets (an initial import can add thousands
    # of phrases; auto-rebaking that would amount to a full-forum rebake,
    # which stays a deliberate admin action).
    def auto_rebake(report)
      return if !SiteSetting.sitemap_autolink_auto_rebake_on_changes

      phrases = (report[:phrases_added] + report[:phrases_removed]).uniq
      return if phrases.empty?

      max_phrases = SiteSetting.sitemap_autolink_auto_rebake_max_phrases
      if phrases.size > max_phrases
        Rails.logger.warn(
          "sitemap-autolink sync: #{phrases.size} phrases changed, above " \
            "sitemap_autolink_auto_rebake_max_phrases (#{max_phrases}) — skipping " \
            "the automatic rebake. This is expected on an initial catalog import; " \
            "existing posts pick up links when next edited or rebaked (e.g. a " \
            "deliberate `rake posts:rebake`, or per-phrase rebakes via the admin API).",
        )
        return
      end

      Jobs.enqueue(
        :sitemap_autolink_rebake_posts,
        phrases: phrases,
        max_posts: SiteSetting.sitemap_autolink_auto_rebake_max_posts,
      )
    end
  end
end
