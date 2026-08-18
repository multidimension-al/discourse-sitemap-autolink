# frozen_string_literal: true

require "net/http"
require "uri"
require "cgi"
require_relative "url_filter"

module SitemapAutolink
  # Periodic catalog synchronization: fetch the configured sitemaps
  # (sitemap indexes are expanded automatically), diff against the stored
  # entries, resolve titles for new/changed URLs (title fetches happen
  # HERE, never during post cooking), regenerate terms, and report what
  # changed so selective rebakes can be enqueued.
  class SitemapSync
    USER_AGENT = "discourse-sitemap-autolink (+https://github.com/multidimension-al/discourse-sitemap-autolink)"
    MAX_TITLE_BYTES = 524_288
    # Sitemap documents are read whole, not just far enough to find a
    # title, and the protocol allows 50,000 URLs (tens of MB) per file.
    # A document truncated by this cap is reported as a failed fetch,
    # never as a short URL list.
    MAX_SITEMAP_BYTES = 8_388_608
    MAX_INDEX_CHILDREN = 100
    # An admin-triggered discovery pass runs inside a web request and
    # fetches one document per child sitemap, so it needs its own cap.
    DISCOVERY_BUDGET_SECONDS = 60
    # How many of a newly seen sitemap's URLs to check against the
    # catalog before deciding it is one we were already importing.
    ADOPTION_SAMPLE = 20
    # Hard wall-clock cap for ONE HTTP fetch. Net::HTTP's read_timeout
    # resets on every byte received, so a tarpitting server that drips
    # a byte every few seconds can otherwise pin a fetch (and the whole
    # sync) indefinitely.
    MAX_FETCH_SECONDS = 30
    # A dry run happens synchronously inside an admin's web request and
    # fetches pages one at a time from the same (possibly slow) server a
    # sync talks to — limit_per_source pages for EVERY configured source,
    # at up to MAX_FETCH_SECONDS each. It needs a wall-clock cap of its
    # own, far shorter than a sync's, or a preview can hold a web worker
    # for many minutes.
    PREVIEW_BUDGET_SECONDS = 60
    CANCEL_KEY = "sitemap_autolink_cancel_requested"
    RUNNING_LOCK_KEY = "sitemap_autolink_sync_running_lock"

    attr_reader :report

    # Admin-requested cancellation: sets a redis flag every running sync
    # polls between URLs, so they stop CLEANLY (recorded as partial,
    # with a note, all completed work kept). The flag deliberately
    # lingers for 10 minutes and also suppresses NEW sync starts — a
    # backlog of queued Sync-now clicks must not revive the work the
    # admin just cancelled. An explicit Sync now clears it.
    def self.request_cancel!
      Discourse.redis.setex(CANCEL_KEY, 600, "1") if defined?(Discourse)
    end

    def self.clear_cancel!
      Discourse.redis.del(CANCEL_KEY) if defined?(Discourse)
    end

    def self.cancel_requested?
      defined?(Discourse) && Discourse.redis.get(CANCEL_KEY).present?
    end

    # sources: [{ url:, type: }]; defaults to the site setting
    #   ("https://example.com/sitemap-products.xml,products|…").
    # title_suffixes: strings stripped from the end of page titles.
    # excluded_url_patterns: see UrlFilter (substring or * wildcard).
    # user_agent: override the identifying UA if a site's WAF needs it.
    # page_fetch_delay_ms: politeness pause between page (title) fetches.
    # fetch_host_rewrites: "public_host=target" pairs — connections for
    #   public_host URLs are made to target (host, host:port, or
    #   scheme://host:port) with a Host: public_host header, bypassing
    #   the public edge/throttling; all stored URLs stay public.
    # time_budget_minutes: overall cap for one run; the next run resumes.
    # on_progress: ->(seen_count) called after each processed URL, so the
    #   caller can surface live progress (the job mirrors it into the
    #   sync-run row for the admin UI).
    # http_get: injectable ->(url, max_bytes) { body_string_or_nil } for tests.
    def initialize(
      sources: nil,
      title_suffixes: nil,
      excluded_url_patterns: nil,
      user_agent: nil,
      page_fetch_delay_ms: nil,
      fetch_host_rewrites: nil,
      time_budget_minutes: nil,
      on_progress: nil,
      http_get: nil
    )
      @sources = sources || parse_sources(SiteSetting.sitemap_autolink_sources)
      @title_suffixes =
        title_suffixes ||
          (
            if defined?(SiteSetting)
              SiteSetting.sitemap_autolink_title_suffixes.split("|").map(&:strip)
            else
              []
            end
          )
      @url_filter =
        UrlFilter.compile(
          excluded_url_patterns ||
            (
              if defined?(SiteSetting)
                SiteSetting.sitemap_autolink_excluded_url_patterns.split("|")
              else
                []
              end
            ),
        )
      @user_agent = user_agent || USER_AGENT
      @fetch_rewrites =
        parse_rewrites(
          fetch_host_rewrites ||
            (defined?(SiteSetting) ? SiteSetting.sitemap_autolink_fetch_host_rewrites : ""),
        )
      @page_fetch_delay =
        (
          page_fetch_delay_ms ||
            (defined?(SiteSetting) ? SiteSetting.sitemap_autolink_page_fetch_delay_ms : 0)
        ).to_i / 1000.0
      @time_budget_minutes =
        (
          time_budget_minutes ||
            (defined?(SiteSetting) ? SiteSetting.sitemap_autolink_sync_time_budget_minutes : 30)
        ).to_f
      @on_progress = on_progress
      @http_get = http_get || method(:default_http_get)
      @report = {
        seen: 0,
        excluded: 0,
        added: [],
        title_changed: [],
        removed: [],
        restored: [],
        phrases_added: [],
        phrases_removed: [],
        errors: [],
        notes: [],
        partial: false,
        pages_fetched: 0,
        fetch_seconds: 0.0,
        slowest_fetches: [],
        deferred_retries: 0,
        pending_sitemaps: [],
        sources: @sources.map { |s| "#{s[:url]} (#{s[:type]})" },
      }
      # Which (entry, sitemap) pairs this run actually observed, and
      # which sitemaps it read end to end — together they say which
      # memberships may safely be pruned afterwards.
      @seen_memberships = Set.new
      @fetched_sitemap_ids = Set.new
      @entry_ids_by_url = {}
    end

    # Never raises: any failure lands in report[:errors] so the sync-run
    # audit row always records what happened, including partial progress.
    def run!
      now = Time.zone.now
      seen_urls = Set.new
      @deadline = monotime + @time_budget_minutes * 60
      stop_early = false

      # With no sources the run gathers no evidence about any URL, so an
      # empty seen-set would sail through mark_removed as a "clean pass"
      # and disable the ENTIRE catalog — while reporting success. The
      # scheduled job refuses to start without sources; `rake
      # sitemap_autolink:sync` and console callers reach here, so the
      # guard belongs on this side too. Recording it as an error is what
      # keeps mark_removed off (and shows the admin why).
      if @sources.empty?
        @report[:errors] << "no sitemap sources configured — nothing to sync " \
          "(set sitemap_autolink_sources)"
      end

      @sources.each do |source|
        break if stop_early
        begin
          entries = fetch_sitemap_entries(source, now: now)
          if entries.nil?
            @report[:errors] << "failed to fetch sitemap #{source[:url]} (unreachable or incomplete)"
            next
          end
          entries.each do |loc, lastmod, listed_in|
            if monotime > @deadline
              # A budget stop is PARTIAL progress, not a failure — it
              # gets its own state so real errors stay meaningful.
              @report[:partial] = true
              @report[:notes] << "stopped at the #{@time_budget_minutes.round}-minute time " \
                "budget after #{@report[:seen]} URLs; the next sync picks up where this left off"
              stop_early = true
              break
            end
            if cancel_requested?
              @report[:partial] = true
              @report[:notes] << "cancelled by admin after #{@report[:seen]} URLs; " \
                "work completed so far is kept"
              stop_early = true
              break
            end
            url = SitemapAutolinkEntry.normalize_url(loc)
            next if url.empty?
            # The same URL is routinely listed in more than one sitemap.
            # It is only synced once, but EVERY listing of it is
            # recorded — otherwise filtering by the second sitemap would
            # not find a page that genuinely appears in it.
            if seen_urls.include?(url)
              record_membership(url, listed_in, now)
              next
            end
            if !ingestible?(url)
              @report[:excluded] += 1
              next
            end
            seen_urls << url
            @report[:seen] += 1
            sync_entry(url, lastmod, source[:type], now, listed_in)
            record_membership(url, listed_in, now)
            @on_progress&.call(@report[:seen])
          end
        rescue => e
          @report[:errors] << "#{source[:url]}: #{e.class} #{e.message}"
        end
      end

      reclean_titles

      begin
        # Removal detection needs a COMPLETE pass over every source; a
        # partial run must not disable the unvisited tail of the catalog.
        if @report[:errors].empty? && !@report[:partial]
          prune_memberships(now)
          mark_removed(seen_urls, now)
        end
      rescue => e
        @report[:errors] << "mark_removed: #{e.class} #{e.message}"
      end
      if @report[:pending_sitemaps].any?
        @report[:notes] << "#{@report[:pending_sitemaps].size} child sitemap(s) are waiting " \
          "for a decision and were NOT imported: #{@report[:pending_sitemaps].join(", ")} " \
          "— approve or ignore them on the plugin's Sitemaps page"
      end
      # Fetch telemetry in the run details: an average that climbs run
      # over run (or a slowest-list full of one host) is the in-product
      # evidence of server-side throttling of the sync's requests.
      if @report[:pages_fetched] > 0
        avg = @report[:fetch_seconds] / @report[:pages_fetched]
        slowest =
          @report[:slowest_fetches]
            .map { |(u, s, trace)| trace ? "#{u} (#{s}s — #{trace})" : "#{u} (#{s}s)" }
            .join(", ")
        @report[:notes] << "fetched #{@report[:pages_fetched]} pages in " \
          "#{@report[:fetch_seconds].round}s (avg #{avg.round(2)}s); slowest: #{slowest}"
      end
      if @report[:deferred_retries] > 0
        @report[:notes] << "#{@report[:deferred_retries]} slow/unreachable pages are in " \
          "title-retry backoff and were skipped this run"
      end

      Catalog.bump_version!
      if defined?(Rails)
        @report[:errors].each { |error| Rails.logger.warn("sitemap-autolink sync: #{error}") }
        @report[:notes].each { |note| Rails.logger.info("sitemap-autolink sync: #{note}") }
      end
      @report
    end

    # Dry run: fetch the configured sitemaps for real, resolve titles and
    # generate phrases for a SAMPLE of URLs — without writing anything.
    # This is the "show me it works" mode, exposed via the admin API,
    # the admin UI, rake sitemap_autolink:preview and script/preview_sync.rb.
    def preview(limit_per_source: 10, term_settings: nil)
      term_settings ||= TermGenerator.default_settings
      deadline = monotime + PREVIEW_BUDGET_SECONDS
      truncated = false
      result = { sources: [], errors: [] }
      @sources.each do |source|
        if monotime > deadline
          truncated = true
          break
        end
        pending_before = @report[:pending_sitemaps].size
        # A dry run must not create or approve anything, so it reads the
        # sitemap records without writing them.
        entries = fetch_sitemap_entries(source, persist: false)
        if entries.nil?
          result[:errors] << "failed to fetch sitemap #{source[:url]}"
          next
        end
        pending = @report[:pending_sitemaps][pending_before..] || []
        # Same normalization and same admission rules a real run applies,
        # or the "what would be ingested" list is not worth reading.
        urls =
          entries.map { |loc, _| SitemapAutolinkEntry.normalize_url(loc) }.reject(&:empty?).uniq
        excluded = urls.reject { |u| ingestible?(u) }
        eligible = urls - excluded
        sampled = []
        eligible.first(limit_per_source).each do |url|
          if monotime > deadline
            truncated = true
            break
          end
          title, title_source = resolve_title(url)
          sampled << {
            url: url,
            title: title,
            title_source: title_source,
            phrases:
              TermGenerator.generate(title.to_s, source[:type], term_settings).map do |c|
                { phrase: c[:phrase], state: c[:state].to_s, reason: c[:reason] }
              end,
          }
        end
        result[:sources] << {
          sitemap: source[:url],
          type: source[:type],
          # Children of an index that nobody has approved yet. Their URLs
          # are NOT in the counts above, which is exactly what a dry run
          # should show: this is what would be imported today.
          pending_sitemaps: pending,
          total_urls: urls.size,
          excluded_by_pattern: excluded.size,
          excluded_sample: excluded.first(10),
          sampled: sampled,
        }
      end
      if truncated
        result[:errors] << "the dry run stopped at its #{PREVIEW_BUDGET_SECONDS}-second budget, " \
          "so the sample above is incomplete — the pages it did reach are slow to answer. " \
          "A real sync is bounded by sitemap_autolink_sync_time_budget_minutes instead, and " \
          "resumes across runs."
      end
      result
    end

    # Fetch one configured source and return [loc, lastmod, sitemap]
    # triples for every URL it lists, where `sitemap` is the record of
    # the document that actually listed it.
    #
    # A <sitemapindex> is NOT expanded wholesale any more. Each child is
    # recorded, and only children an admin has enabled are imported;
    # newly discovered ones are fetched once purely to record their kind
    # and URL count, so the decision can be made against a number. An
    # index whose children hold tens of thousands of URLs used to become
    # an unannounced import of all of them.
    #
    # A sitemap missing its closing tag (truncated by size caps, fetch
    # deadline, or a broken connection) counts as a FAILED fetch, never a
    # partial success — a partial URL list would otherwise mark every
    # unlisted entry as removed from the source.
    def fetch_sitemap_entries(source, now: Time.zone.now, persist: true)
      source = { url: source, type: "content" } if source.is_a?(String)
      record =
        sitemap_record(
          url: source[:url],
          content_type: source[:type],
          parent_url: nil,
          configured: true,
          now: now,
          persist: persist,
        )
      xml = to_utf8(@http_get.call(source[:url], MAX_SITEMAP_BYTES))
      if xml.nil? || !complete_sitemap?(xml)
        touch_sitemap(record, now: now, persist: persist, error: "unreachable or incomplete")
        return nil
      end

      if xml =~ /<sitemapindex[\s>]/i
        touch_sitemap(record, now: now, persist: persist, kind: SitemapAutolinkSitemap::INDEX)
        children = parse_sitemap(xml)
        if children.size > MAX_INDEX_CHILDREN
          # A capped child list is INCOMPLETE coverage: on a clean run
          # mark_removed would disable every entry that lives only in
          # the dropped children. Partial keeps removal decisions off.
          @report[:partial] = true
          @report[:notes] << "sitemap index #{source[:url]} lists #{children.size} child " \
            "sitemaps; only the first #{MAX_INDEX_CHILDREN} were processed (entries beyond " \
            "the cap keep their current state)"
          children = children.first(MAX_INDEX_CHILDREN)
        end
        entries = []
        children.each do |child_loc, _lastmod|
          child_url = SitemapAutolinkSitemap.normalize_url(child_loc)
          next if child_url.empty?
          child =
            sitemap_record(
              url: child_url,
              content_type: source[:type],
              parent_url: source[:url],
              configured: false,
              now: now,
              persist: persist,
            )
          # Declined outright: never fetched, never counted, never
          # imported. That is what ignoring one is for.
          next if child.status == SitemapAutolinkSitemap::IGNORED
          if child.status == SitemapAutolinkSitemap::PENDING
            # Measuring can conclude this is a sitemap we were already
            # importing from, in which case it is approved on the spot
            # and imported in this same run — no gap.
            measure_sitemap(child, now: now, persist: persist)
            if child.status == SitemapAutolinkSitemap::PENDING
              @report[:pending_sitemaps] << child_url
              next
            end
          end
          locs = read_child_sitemap(child, now: now, persist: persist)
          next if locs.nil?
          locs.each { |loc, lastmod| entries << [loc, lastmod, child] }
        end
        entries
      else
        locs = parse_sitemap(xml)
        touch_sitemap(
          record,
          now: now,
          persist: persist,
          kind: SitemapAutolinkSitemap::URLSET,
          url_count: locs.size,
          fetched: true,
        )
        @fetched_sitemap_ids << record.id if record.id
        locs.map { |loc, lastmod| [loc, lastmod, record] }
      end
    end

    # Walk the configured sources recording what is there — sitemaps,
    # their kind and their size — without ingesting a single URL. This is
    # what the admin Sitemaps page runs so an index's children can be
    # seen (and counted) before anything is decided about them.
    def discover!
      now = Time.zone.now
      deadline = monotime + DISCOVERY_BUDGET_SECONDS
      @sources.each do |source|
        break if monotime > deadline
        begin
          # The URL list is deliberately discarded; the point of the pass
          # is the sitemap records it writes on the way through.
          fetch_sitemap_entries(source, now: now)
        rescue => e
          @report[:errors] << "#{source[:url]}: #{e.class} #{e.message}"
        end
      end
      if monotime > deadline
        @report[:partial] = true
        @report[:notes] << "discovery stopped at its #{DISCOVERY_BUDGET_SECONDS}-second budget; " \
          "run it again to finish reading the remaining sitemaps"
      end
      @report
    end

    # An enabled child: fetched in full, its URLs returned for import.
    def read_child_sitemap(child, now:, persist:)
      xml = to_utf8(@http_get.call(child.url, MAX_SITEMAP_BYTES))
      if xml.nil? || !complete_sitemap?(xml)
        @report[:errors] << "failed to fetch child sitemap #{child.url} " \
          "(unreachable or incomplete)"
        touch_sitemap(child, now: now, persist: persist, error: "unreachable or incomplete")
        return nil
      end
      locs = parse_sitemap(xml)
      kind =
        xml =~ /<sitemapindex[\s>]/i ? SitemapAutolinkSitemap::INDEX : SitemapAutolinkSitemap::URLSET
      # Sitemap indexes nest only one level here: a child that is itself
      # an index is recorded and reported, not recursed into.
      if kind == SitemapAutolinkSitemap::INDEX
        touch_sitemap(child, now: now, persist: persist, kind: kind, fetched: true)
        @report[:notes] << "#{child.url} is itself a sitemap index; nested indexes are not " \
          "expanded — add it as its own source if you want its children"
        return nil
      end
      touch_sitemap(
        child,
        now: now,
        persist: persist,
        kind: kind,
        url_count: locs.size,
        fetched: true,
      )
      @fetched_sitemap_ids << child.id if child.id
      locs
    end

    # A sitemap nobody has decided about yet is fetched ONCE, to answer
    # the only question that matters at that point: how big is it. The
    # admin approving or ignoring it needs that number, and re-reading it
    # on every sync would be the very cost they are trying to avoid.
    def measure_sitemap(child, now:, persist:)
      return if child.last_fetched_at.present?
      xml = to_utf8(@http_get.call(child.url, MAX_SITEMAP_BYTES))
      if xml.nil?
        touch_sitemap(child, now: now, persist: persist, error: "unreachable")
        return
      end
      complete = complete_sitemap?(xml)
      kind =
        xml =~ /<sitemapindex[\s>]/i ? SitemapAutolinkSitemap::INDEX : SitemapAutolinkSitemap::URLSET
      locs = parse_sitemap(xml)
      touch_sitemap(
        child,
        now: now,
        persist: persist,
        kind: kind,
        url_count: locs.size,
        # A document cut off by the size cap yields a floor, not a total.
        url_count_partial: !complete,
        fetched: true,
      )
      adopt_if_already_imported(child, locs, persist: persist)
    end

    # A child sitemap whose URLs are ALREADY in the catalog is not a new
    # decision — it is the sitemap that has been feeding this install all
    # along, seen for the first time as a record of its own. Approving it
    # automatically is what keeps the opt-in from retroactively
    # un-importing a working catalog (and, via mark_removed, disabling
    # every page in it) the first time a site upgrades.
    def adopt_if_already_imported(child, locs, persist:)
      return if !persist || child.id.nil?
      sample =
        locs
          .first(ADOPTION_SAMPLE)
          .map { |loc, _lastmod| SitemapAutolinkEntry.normalize_url(loc) }
          .reject(&:empty?)
          .select { |url| ingestible?(url) }
      return if sample.empty?
      known = SitemapAutolinkEntry.where(url: sample).count
      return if known * 2 <= sample.size
      child.update_columns(status: SitemapAutolinkSitemap::ENABLED)
      @report[:notes] << "#{child.url} lists URLs already in the catalog, so it was kept as an " \
        "imported sitemap rather than held for approval"
    end

    def sitemap_record(url:, content_type:, parent_url:, configured:, now:, persist:)
      url = SitemapAutolinkSitemap.normalize_url(url)
      record = SitemapAutolinkSitemap.find_by(url: url)
      if record.nil?
        record =
          SitemapAutolinkSitemap.new(
            url: url,
            content_type: content_type.presence || "content",
            parent_url: parent_url,
            configured: configured,
            # A source the admin typed into the setting is approved by
            # that act. A child discovered inside an index is not.
            status:
              if configured || new_children_auto_imported?
                SitemapAutolinkSitemap::ENABLED
              else
                SitemapAutolinkSitemap::PENDING
              end,
            last_seen_at: now,
          )
        record.save! if persist
        return record
      end
      return record if !persist
      changes = { last_seen_at: now }
      # A source's content type and its place in the tree follow the
      # setting, so fixing either of them there takes effect on the next
      # pass. The import decision is the admin's and is never rewritten.
      changes[:content_type] = content_type if content_type.present? &&
        record.content_type != content_type
      changes[:parent_url] = parent_url if record.parent_url != parent_url
      changes[:configured] = configured if record.configured != configured
      # Re-typing a configured source into the setting re-approves it.
      if configured && record.status != SitemapAutolinkSitemap::ENABLED
        changes[:status] = SitemapAutolinkSitemap::ENABLED
      end
      record.update_columns(changes)
      record
    end

    def touch_sitemap(record, now:, persist:, **changes)
      return record if !persist || record.nil? || record.id.nil?
      attrs = { last_seen_at: now }
      attrs[:kind] = changes[:kind] if changes[:kind]
      attrs[:url_count] = changes[:url_count] if changes.key?(:url_count)
      attrs[:url_count_partial] = !!changes[:url_count_partial] if changes.key?(:url_count) ||
        changes.key?(:url_count_partial)
      attrs[:last_fetched_at] = now if changes[:fetched] || changes[:kind]
      attrs[:last_error] = changes[:error]
      record.update_columns(attrs)
      record
    end

    def new_children_auto_imported?
      return false if !defined?(SiteSetting)
      SiteSetting.sitemap_autolink_auto_import_new_sitemaps
    end

    # Membership is recorded per listing, so a URL in two sitemaps is
    # findable under both. Deduplicated in memory because a big sitemap
    # can list the same URL many times.
    def record_membership(url, sitemap, now)
      return if sitemap.nil? || sitemap.id.nil?
      entry_id = @entry_ids_by_url[url] ||= SitemapAutolinkEntry.where(url: url).pick(:id)
      return if entry_id.nil?
      key = [entry_id, sitemap.id]
      return if @seen_memberships.include?(key)
      @seen_memberships << key
      row =
        SitemapAutolinkEntrySitemap.find_or_initialize_by(entry_id: entry_id, sitemap_id: sitemap.id)
      row.last_seen_at = now
      row.save!
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    # A URL that dropped out of one sitemap but still sits in another
    # must lose only that membership. Only sitemaps this run read END TO
    # END are pruned — a sitemap that failed to fetch tells us nothing
    # about what it no longer contains.
    def prune_memberships(now)
      return if @fetched_sitemap_ids.empty?
      # Every membership observed this run was stamped with `now`, so
      # anything older is one this sitemap no longer lists. Comparing
      # timestamps keeps this to one statement per sitemap instead of an
      # IN list holding every URL in the catalog.
      SitemapAutolinkEntrySitemap
        .where(sitemap_id: @fetched_sitemap_ids.to_a)
        .where("last_seen_at IS NULL OR last_seen_at < ?", now)
        .delete_all
    end

    def complete_sitemap?(xml)
      xml.match?(%r{</\s*(urlset|sitemapindex)\s*>}i)
    end

    # Shared by the real run and the dry run. The sitemap protocol only
    # allows absolute http(s) <loc> values; anything else (javascript:,
    # data:, ftp:, …) is malformed or malicious and must never enter the
    # catalog — nor a preview's "would be ingested" list.
    def ingestible?(url)
      url.match?(%r{\Ahttps?://}i) && !UrlFilter.excluded?(url, @url_filter)
    end

    def cancel_requested?
      self.class.cancel_requested?
    end

    def monotime
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # 1 failure → retry tomorrow; then 2 days, 4 days, capped at weekly.
    def title_retry_backoff(failures)
      [2**[failures - 1, 0].max, 7].min.days
    end

    # "public_host=target" rows; target may be host, host:port, or
    # scheme://host:port. Bad rows are skipped.
    def parse_rewrites(setting)
      rows = setting.is_a?(String) ? setting.split("|") : Array(setting)
      rows.each_with_object({}) do |row, map|
        public_host, target = row.to_s.split("=", 2)&.map(&:strip)
        next if public_host.nil? || public_host.empty? || target.nil? || target.empty?
        begin
          if target.include?("://")
            t = URI.parse(target)
            next if t.host.nil?
            map[public_host.downcase] = { scheme: t.scheme, host: t.host, port: t.port }
          else
            host, port = target.split(":")
            map[public_host.downcase] = { scheme: nil, host: host, port: port&.to_i }
          end
        rescue URI::InvalidURIError
          next
        end
      end
    end

    def sync_entry(url, lastmod, content_type, now, _listed_in = nil)
      entry = SitemapAutolinkEntry.find_by(url: url)

      if entry.nil?
        title, title_source = throttled_resolve_title(url)
        entry =
          SitemapAutolinkEntry.create!(
            url: url,
            title: title,
            content_type: content_type,
            source: "sitemap",
            title_source: title_source,
            lastmod: lastmod,
            auto_discovered: true,
            first_seen_at: now,
            last_seen_at: now,
            title_fetch_failures: title_source == "slug" ? 1 : 0,
            next_title_fetch_at: title_source == "slug" ? now + title_retry_backoff(1) : nil,
          )
        @entry_ids_by_url[url] = entry.id
        regenerate_terms(entry)
        @report[:added] << url
        return
      end

      @entry_ids_by_url[url] = entry.id

      if entry.removed_from_source
        entry.update!(removed_from_source: false, last_seen_at: now)
        @report[:restored] << url
        @report[:phrases_added].concat(active_phrases(entry))
      end

      # A source's content type is authoritative for auto-discovered
      # entries: fixing the type in sitemap_autolink_sources re-types
      # existing entries on the next sync.
      if entry.auto_discovered && entry.content_type != content_type
        entry.update!(content_type: content_type)
      end

      changed = lastmod.present? && lastmod != entry.lastmod
      # Slug-titled entries retry their title fetch — but on a BACKOFF
      # schedule after failures. A page slower than the fetch cap can
      # never deliver a title, and without backoff such pages tax every
      # run ~cap seconds each, forever (a lastmod change still forces a
      # fresh attempt).
      retry_due =
        entry.next_title_fetch_at.nil? || entry.next_title_fetch_at <= now
      slug_title = entry.title_source == "slug"
      if slug_title && !retry_due && !changed
        @report[:deferred_retries] += 1
        entry.update_columns(last_seen_at: now)
        return
      end
      if changed || slug_title
        title, title_source = throttled_resolve_title(url)
        if title_source == "page"
          if title != entry.title
            entry.update!(
              title: title,
              title_source: title_source,
              lastmod: lastmod,
              last_seen_at: now,
              title_fetch_failures: 0,
              next_title_fetch_at: nil,
            )
            regenerate_terms(entry)
            @report[:title_changed] << url
          else
            # The fetched title can be IDENTICAL to the stored slug title
            # (wiki pages named exactly like their slug, e.g. a person's
            # name). The heal must still flip title_source to "page", or
            # the entry re-downloads its page on every sync forever.
            entry.update!(
              title_source: "page",
              lastmod: lastmod,
              last_seen_at: now,
              title_fetch_failures: 0,
              next_title_fetch_at: nil,
            )
          end
          return
        end
        failures = entry.title_fetch_failures + 1
        entry.update!(
          lastmod: lastmod,
          last_seen_at: now,
          title_fetch_failures: failures,
          next_title_fetch_at: now + title_retry_backoff(failures),
        )
        return
      end

      entry.update_columns(last_seen_at: now)
    rescue => e
      @report[:errors] << "#{url}: #{e.class} #{e.message}"
    end

    # Entries that stopped appearing in any sitemap are disabled (not
    # deleted — manual state and history stay), and their phrases go in
    # the removal report so affected posts can be rebaked.
    def mark_removed(seen_urls, _now)
      SitemapAutolinkEntry
        .where(removed_from_source: false, auto_discovered: true)
        .where(source: "sitemap")
        .find_each do |entry|
          next if seen_urls.include?(entry.url)
          @report[:phrases_removed].concat(active_phrases(entry))
          entry.update!(removed_from_source: true)
          @report[:removed] << entry.url
        end
    end

    # Replace GENERATED terms with a fresh generation, preserving any
    # term the admin touched (manual origin, approved or disabled state).
    def regenerate_terms(entry)
      old_phrases = active_phrases(entry)
      keep_states = %w[approved disabled]
      entry
        .terms
        .where(origin: SitemapAutolinkTerm.origins[:generated])
        .where.not(state: keep_states)
        .destroy_all

      TermGenerator
        .generate(entry.title, entry.content_type)
        .each do |candidate|
          normalized = Matcher.normalize(candidate[:phrase])
          next if entry.terms.exists?(normalized_phrase: normalized)
          entry.terms.create!(
            phrase: candidate[:phrase],
            state: candidate[:state],
            origin: :generated,
            review_reason: candidate[:reason],
          )
        end

      new_phrases = active_phrases(entry.reload)
      @report[:phrases_added].concat(new_phrases - old_phrases)
      @report[:phrases_removed].concat(old_phrases - new_phrases)
    end

    def active_phrases(entry)
      return [] if !entry.enabled || entry.removed_from_source
      entry.terms.linkable.pluck(:normalized_phrase)
    end

    # HTTP bodies may arrive as raw binary; normalize to valid UTF-8
    # before any text processing (bad byte sequences become "").
    def to_utf8(body)
      return body if body.nil?
      return body if body.encoding == Encoding::UTF_8 && body.valid_encoding?
      body.dup.force_encoding(Encoding::UTF_8).scrub("")
    end

    # Politeness spacing for the per-page title fetches during a real
    # sync: without it, a first import of hundreds/thousands of URLs is
    # a request burst that firewalls read as scraping (and may answer by
    # banning the forum's IP). Sitemap fetches and dry-run previews
    # (bounded samples) are not delayed.
    def throttled_resolve_title(url)
      sleep(@page_fetch_delay) if @page_fetch_delay.positive?
      resolve_title(url)
    end

    def resolve_title(url)
      started = monotime
      body = to_utf8(@http_get.call(url, MAX_TITLE_BYTES))
      record_fetch_time(url, monotime - started)
      title = body && title_from_html(body)
      return [title, "page"] if title.present?
      [title_from_slug(url), "slug"]
    end

    def record_fetch_time(url, elapsed)
      @report[:pages_fetched] += 1
      @report[:fetch_seconds] += elapsed
      slowest = @report[:slowest_fetches]
      slowest << [url, elapsed.round(1), fetch_trace_summary]
      slowest.sort_by! { |(_u, s, _t)| -s }
      slowest.pop while slowest.size > 5
    end

    # Compact phase breakdown of the last default_http_get call, so a
    # slow fetch in the telemetry says WHERE the time went (connect,
    # waiting for the first byte, hop count, exception class) instead
    # of leaving it to guesswork.
    def fetch_trace_summary
      t = @fetch_trace
      return nil if t.nil?
      parts = []
      parts << "#{t[:hops]} hops" if t[:hops].to_i > 1
      parts << "connect #{t[:connect_s]}s" if t[:connect_s]
      parts << "first byte #{t[:first_byte_s]}s" if t[:first_byte_s]
      parts << t[:error] if t[:error]
      parts.empty? ? nil : parts.join(", ")
    end

    # The attribute value ends at the SAME quote character that opened
    # it: content="Foreman's Field Guide" legitimately contains an
    # apostrophe, content='He said "now"' a double quote. Matching
    # either quote kind as the terminator ([^"']) truncated such titles
    # at the embedded quote ("Foreman's…" ingested as "Foreman").
    OG_TITLE_PROPERTY_FIRST =
      /<meta[^>]+property=["']og:title["'][^>]+content=(["'])((?:(?!\1).)+)\1/im
    OG_TITLE_CONTENT_FIRST =
      /<meta[^>]+content=(["'])((?:(?!\1).)+)\1[^>]+property=["']og:title["']/im

    def title_from_html(html)
      raw =
        html[OG_TITLE_PROPERTY_FIRST, 2] || html[OG_TITLE_CONTENT_FIRST, 2] ||
          html[%r{<title[^>]*>([^<]+)</title>}i, 1]
      return nil if raw.nil?
      clean_title(CGI.unescapeHTML(raw))
    end

    # Connector punctuation left dangling at the END of a title after a
    # suffix strip. Discourse list settings use | as the entry
    # separator, so a suffix containing | ("… Wiki | Example.com") can
    # only be configured as fragments — trimming dangling connectors
    # between strips lets those fragments compose correctly.
    TRAILING_SEPARATORS = /[\s|\-–—·:•]+\z/

    # Shared title hygiene: drop backslash-escaping of quotes leaking
    # from the source CMS (PHP addslashes artifacts like "Mattel\'s"),
    # then strip the configured suffixes repeatedly.
    def clean_title(raw)
      return nil if raw.nil?
      title = raw.gsub(/\\+(['"])/, '\1').strip
      loop do
        stripped = @title_suffixes.find { |s| s.present? && title.downcase.end_with?(s.downcase) }
        break if stripped.nil?
        title = title[0, title.length - stripped.length].strip
        title = title.sub(TRAILING_SEPARATORS, "").strip
      end
      title.presence
    end

    # Title hygiene is settings-driven, so re-apply it to STORED titles
    # on every run (no page fetches): a suffix pattern configured after
    # entries were ingested would otherwise stay baked into their titles
    # (and phrases) until the page's lastmod happened to change.
    def reclean_titles
      SitemapAutolinkEntry
        .where(auto_discovered: true, removed_from_source: false)
        .find_each do |entry|
          cleaned = clean_title(entry.title)
          next if cleaned.blank? || cleaned == entry.title
          entry.update!(title: cleaned)
          regenerate_terms(entry)
          @report[:title_changed] << entry.url
        end
    rescue => e
      @report[:errors] << "reclean_titles: #{e.class} #{e.message}"
    end

    def title_from_slug(url)
      url
        .split("/")
        .last
        .to_s
        .split("-")
        .map { |w| w.match?(/\A\d/) ? w : w.capitalize }
        .join(" ")
    end

    # <loc> holds XML, and the sitemap protocol REQUIRES its reserved
    # characters to be escaped — an ampersand is written &amp;. Storing
    # the escaped text verbatim would point every query-string URL at a
    # different page than the sitemap named (?a=1&amp;b=2 asks for a
    # parameter literally called "amp;b"), so unescape before the URL is
    # normalized, fetched or stored.
    def parse_sitemap(xml)
      xml
        .split(%r{</url>|</sitemap>}i)
        .filter_map do |block|
          loc = block[%r{<loc>\s*([^<\s]+)\s*</loc>}i, 1]
          next if loc.nil?
          [CGI.unescapeHTML(loc), block[%r{<lastmod>\s*([^<\s]+)\s*</lastmod>}i, 1]]
        end
    end

    def parse_sources(setting)
      setting
        .split("|")
        .filter_map do |row|
          url, type = row.split(",").map(&:strip)
          { url: url, type: type.presence || "content" } if url.present?
        end
    end

    # Streaming GET with an identifying UA, redirect following and an
    # early abort once enough of the page arrived to contain the title.
    # Accumulates in binary (chunks arrive as ASCII-8BIT; mixing them
    # into a UTF-8 string raises Encoding::CompatibilityError on pages
    # with typographic characters); callers convert via to_utf8.
    # The deadline is set ONCE per top-level fetch and shared across
    # redirect hops — per-hop clocks let a slow redirect chain (or a
    # server that stalls before its first body byte) stack timeouts
    # well past the intended cap.
    def default_http_get(url, max_bytes, redirects_left = 3, deadline = nil)
      if deadline.nil?
        deadline = monotime + MAX_FETCH_SECONDS
        @fetch_trace = { hops: 0 }
      end
      return nil if monotime > deadline
      @fetch_trace[:hops] += 1
      uri = URI.parse(url)
      target = @fetch_rewrites[uri.host.to_s.downcase]
      scheme = target&.[](:scheme) || uri.scheme
      connect_host = target ? target[:host] : uri.host
      connect_port = target ? (target[:port] || (scheme == "https" ? 443 : 80)) : uri.port
      body = +"".b
      started = monotime
      Net::HTTP.start(
        connect_host,
        connect_port,
        use_ssl: scheme == "https",
        open_timeout: 10,
        read_timeout: 15,
      ) do |http|
        # Net::HTTP silently RETRIES an idempotent request once when the
        # server kills the connection — stacking two full timeout waits
        # onto one "fetch". Our retry policy lives in the backoff
        # schedule, not hidden inside the HTTP client.
        http.max_retries = 0
        @fetch_trace[:connect_s] = (monotime - started).round(1)
        requested = monotime
        headers = { "User-Agent" => @user_agent, "Accept" => "text/html,application/xml" }
        # When connecting to an internal target, the app still needs to
        # see the PUBLIC host to route and render the right site.
        headers["Host"] = uri.host if target
        request = Net::HTTP::Get.new(uri, headers)
        http.request(request) do |response|
          @fetch_trace[:first_byte_s] = (monotime - requested).round(1)
          if response.is_a?(Net::HTTPRedirection) && redirects_left.positive?
            location = response["location"]
            return nil if location.blank?
            return default_http_get(URI.join(url, location).to_s, max_bytes, redirects_left - 1, deadline)
          end
          return nil unless response.is_a?(Net::HTTPSuccess)
          response.read_body do |chunk|
            body << chunk
            break if body.bytesize >= max_bytes
            break if monotime > deadline
            break if body.include?("</title>")
          end
        end
      end
      body
    rescue StandardError => e
      @fetch_trace[:error] = e.class.name if @fetch_trace
      nil
    end
  end
end
