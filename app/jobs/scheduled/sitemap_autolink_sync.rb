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

      _run, report =
        SitemapAutolinkSyncRun.record(triggered_by: triggered_by) do
          SitemapAutolink::SitemapSync.new.run!
        end

      Rails.logger.info(
        "sitemap-autolink sync (#{triggered_by}): #{report[:seen]} urls seen, " \
          "#{report[:excluded]} excluded by pattern, #{report[:added].size} added, " \
          "#{report[:title_changed].size} retitled, #{report[:removed].size} removed, " \
          "#{report[:errors].size} errors",
      )

      auto_rebake(report)
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
