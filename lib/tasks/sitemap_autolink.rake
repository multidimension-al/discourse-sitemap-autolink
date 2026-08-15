# frozen_string_literal: true

# Operational proof from the console:
#   rake sitemap_autolink:report        catalog + sync-run summary
#   rake sitemap_autolink:preview[20]   live dry run, nothing written
#   rake sitemap_autolink:sync          run a sync now, print the report

namespace :sitemap_autolink do
  desc "Print catalog status, recent sync runs and pending terms"
  task report: :environment do
    puts "enabled:           #{SiteSetting.sitemap_autolink_enabled}"
    puts "sync enabled:      #{SiteSetting.sitemap_autolink_sync_enabled}"
    puts "sources:           #{SiteSetting.sitemap_autolink_sources.presence || "(none configured)"}"
    puts "catalog version:   #{SitemapAutolink::Catalog.version}"
    puts "active link rules: #{SitemapAutolink::Catalog.ruleset.size}"
    puts "entries:           #{SitemapAutolinkEntry.count} (#{SitemapAutolinkEntry.active.count} active)"
    puts "terms:             #{SitemapAutolinkTerm.count} (#{SitemapAutolinkTerm.pending_review.count} pending review)"
    puts "\nRecent sync runs:"
    SitemapAutolinkSyncRun.recent.limit(10).each do |run|
      puts "  #{run.started_at} [#{run.triggered_by}] #{run.success ? "OK" : "FAILED"} " \
             "seen=#{run.urls_seen} excluded=#{run.urls_excluded} added=#{run.entries_added} " \
             "retitled=#{run.entries_retitled} removed=#{run.entries_removed}"
      puts "    errors: #{run.error_details.lines.first&.strip}" if run.error_details.present?
    end
    puts "\nSample entries:"
    SitemapAutolinkEntry.active.order(:id).limit(10).each do |entry|
      phrases = entry.terms.linkable.pluck(:phrase)
      puts "  [#{entry.content_type}] #{entry.title} -> #{entry.url}"
      puts "     links on: #{phrases.join(", ")}" if phrases.any?
    end
    pending = SitemapAutolinkTerm.pending_review.includes(:entry).limit(20)
    if pending.any?
      puts "\nPending review (first 20):"
      pending.each do |term|
        puts "  \"#{term.phrase}\" (#{term.review_reason}) -> #{term.entry.url}"
      end
    end
  end

  desc "Dry run: fetch sitemaps, show what WOULD be ingested (writes nothing)"
  task :preview, [:limit] => :environment do |_t, args|
    limit = (args[:limit] || 10).to_i
    result = SitemapAutolink::SitemapSync.new.preview(limit_per_source: limit)
    result[:errors].each { |e| puts "ERROR: #{e}" }
    result[:sources].each do |source|
      puts "\n#{source[:sitemap]} (type: #{source[:type]})"
      puts "  URLs in sitemap: #{source[:total_urls]}  excluded by pattern: #{source[:excluded_by_pattern]}"
      source[:excluded_sample].each { |u| puts "    excluded: #{u}" }
      source[:sampled].each do |page|
        puts "  #{page[:url]}"
        puts "    title (#{page[:title_source]}): #{page[:title]}"
        page[:phrases].each do |p|
          note = p[:state] == "auto_active" ? "ACTIVE" : "review: #{p[:reason]}"
          puts "    would link \"#{p[:phrase]}\" [#{note}]"
        end
      end
    end
  end

  desc "Run a catalog sync now and print the report"
  task sync: :environment do
    run, report =
      SitemapAutolinkSyncRun.record(triggered_by: "rake") do
        SitemapAutolink::SitemapSync.new.run!
      end
    puts "sync run ##{run.id}: #{run.success ? "OK" : "FAILED"}"
    puts "  urls seen:     #{report[:seen]} (#{report[:excluded]} excluded by pattern)"
    puts "  added:         #{report[:added].size}"
    puts "  retitled:      #{report[:title_changed].size}"
    puts "  removed:       #{report[:removed].size}"
    puts "  phrases +/-:   #{report[:phrases_added].size}/#{report[:phrases_removed].size}"
    report[:errors].first(10).each { |e| puts "  ERROR: #{e}" }
  end
end
