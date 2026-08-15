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

      if SiteSetting.sitemap_autolink_auto_rebake_on_changes
        phrases = (report[:phrases_added] + report[:phrases_removed]).uniq
        phrases.each do |phrase|
          Jobs.enqueue(:sitemap_autolink_selective_rebake, phrase: phrase)
        end
      end
    end
  end
end
