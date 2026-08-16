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
    USER_AGENT = "discourse-sitemap-autolink/0.2 (catalog sync)"
    MAX_TITLE_BYTES = 524_288
    MAX_INDEX_CHILDREN = 100
    # Hard wall-clock cap for ONE HTTP fetch. Net::HTTP's read_timeout
    # resets on every byte received, so a tarpitting server that drips
    # a byte every few seconds can otherwise pin a fetch (and the whole
    # sync) indefinitely.
    MAX_FETCH_SECONDS = 30
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
        sources: @sources.map { |s| "#{s[:url]} (#{s[:type]})" },
      }
    end

    # Never raises: any failure lands in report[:errors] so the sync-run
    # audit row always records what happened, including partial progress.
    def run!
      now = Time.zone.now
      seen_urls = Set.new
      @deadline = monotime + @time_budget_minutes * 60
      stop_early = false

      @sources.each do |source|
        break if stop_early
        begin
          entries = fetch_sitemap_entries(source[:url])
          if entries.nil?
            @report[:errors] << "failed to fetch sitemap #{source[:url]} (unreachable or incomplete)"
            next
          end
          entries.each do |loc, lastmod|
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
            next if url.empty? || seen_urls.include?(url)
            if UrlFilter.excluded?(url, @url_filter)
              @report[:excluded] += 1
              next
            end
            seen_urls << url
            @report[:seen] += 1
            sync_entry(url, lastmod, source[:type], now)
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
        mark_removed(seen_urls, now) if @report[:errors].empty? && !@report[:partial]
      rescue => e
        @report[:errors] << "mark_removed: #{e.class} #{e.message}"
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
        @report[:errors].each { |e| Rails.logger.warn("sitemap-autolink sync: #{e}") }
        @report[:notes].each { |n| Rails.logger.info("sitemap-autolink sync: #{n}") }
      end
      @report
    end

    # Dry run: fetch the configured sitemaps for real, resolve titles and
    # generate phrases for a SAMPLE of URLs — without writing anything.
    # This is the "show me it works" mode, exposed via the admin API,
    # the admin UI, rake sitemap_autolink:preview and script/preview_sync.rb.
    def preview(limit_per_source: 10, term_settings: nil)
      term_settings ||= TermGenerator.default_settings
      result = { sources: [], errors: [] }
      @sources.each do |source|
        entries = fetch_sitemap_entries(source[:url])
        if entries.nil?
          result[:errors] << "failed to fetch sitemap #{source[:url]}"
          next
        end
        urls = entries.map { |loc, _| loc.strip }.uniq
        excluded = urls.select { |u| UrlFilter.excluded?(u, @url_filter) }
        eligible = urls - excluded
        sampled =
          eligible.first(limit_per_source).map do |url|
            title, title_source = resolve_title(url)
            {
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
          total_urls: urls.size,
          excluded_by_pattern: excluded.size,
          excluded_sample: excluded.first(10),
          sampled: sampled,
        }
      end
      result
    end

    # Fetch one configured source. A <sitemapindex> is expanded into its
    # child sitemaps (one level, same content type). A sitemap missing
    # its closing tag (truncated by size caps, fetch deadline, or a
    # broken connection) counts as a FAILED fetch, never a partial
    # success — a partial URL list would otherwise mark every unlisted
    # entry as removed from the source.
    def fetch_sitemap_entries(url)
      xml = to_utf8(@http_get.call(url, MAX_TITLE_BYTES * 4))
      return nil if xml.nil? || !complete_sitemap?(xml)
      if xml =~ /<sitemapindex[\s>]/i
        children = parse_sitemap(xml).first(MAX_INDEX_CHILDREN)
        entries = []
        children.each do |child_loc, _lastmod|
          child_xml = to_utf8(@http_get.call(child_loc.strip, MAX_TITLE_BYTES * 4))
          if child_xml.nil? || !complete_sitemap?(child_xml)
            @report[:errors] << "failed to fetch child sitemap #{child_loc} (unreachable or incomplete)"
            next
          end
          entries.concat(parse_sitemap(child_xml))
        end
        entries
      else
        parse_sitemap(xml)
      end
    end

    def complete_sitemap?(xml)
      xml.match?(%r{</\s*(urlset|sitemapindex)\s*>}i)
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

    def sync_entry(url, lastmod, content_type, now)
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
        regenerate_terms(entry)
        @report[:added] << url
        return
      end

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

    def title_from_html(html)
      raw =
        html[/<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']/i, 1] ||
          html[/<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:title["']/i, 1] ||
          html[%r{<title[^>]*>([^<]+)</title>}i, 1]
      return nil if raw.nil?
      clean_title(CGI.unescapeHTML(raw))
    end

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

    def parse_sitemap(xml)
      xml
        .split(%r{</url>|</sitemap>}i)
        .filter_map do |block|
          loc = block[%r{<loc>\s*([^<\s]+)\s*</loc>}i, 1]
          next if loc.nil?
          [loc, block[%r{<lastmod>\s*([^<\s]+)\s*</lastmod>}i, 1]]
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
      body = +"".b
      started = monotime
      Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
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
        request = Net::HTTP::Get.new(uri, "User-Agent" => @user_agent, "Accept" => "text/html,application/xml")
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
