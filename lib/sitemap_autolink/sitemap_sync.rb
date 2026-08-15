# frozen_string_literal: true

require "net/http"
require "uri"

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

    attr_reader :report

    # sources: [{ url:, type: }]; defaults to the site setting
    #   ("https://example.com/sitemap-products.xml,products|…").
    # title_suffixes: strings stripped from the end of page titles.
    # http_get: injectable ->(url, max_bytes) { body_string_or_nil } for tests.
    def initialize(sources: nil, title_suffixes: nil, http_get: nil)
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
      @http_get = http_get || method(:default_http_get)
      @report = {
        seen: 0,
        added: [],
        title_changed: [],
        removed: [],
        restored: [],
        phrases_added: [],
        phrases_removed: [],
        errors: [],
      }
    end

    def run!
      now = Time.zone.now
      seen_urls = Set.new

      @sources.each do |source|
        entries = fetch_sitemap_entries(source[:url])
        if entries.nil?
          @report[:errors] << "failed to fetch sitemap #{source[:url]}"
          next
        end
        entries.each do |loc, lastmod|
          url = SitemapAutolinkEntry.normalize_url(loc)
          next if url.empty? || seen_urls.include?(url)
          seen_urls << url
          @report[:seen] += 1
          sync_entry(url, lastmod, source[:type], now)
        end
      end

      mark_removed(seen_urls, now) if @report[:errors].empty?
      Catalog.bump_version!
      @report
    end

    # Fetch one configured source. A <sitemapindex> is expanded into its
    # child sitemaps (one level, same content type).
    def fetch_sitemap_entries(url)
      xml = @http_get.call(url, MAX_TITLE_BYTES * 4)
      return nil if xml.nil?
      if xml =~ /<sitemapindex[\s>]/i
        children = parse_sitemap(xml).first(MAX_INDEX_CHILDREN)
        entries = []
        children.each do |child_loc, _lastmod|
          child_xml = @http_get.call(child_loc.strip, MAX_TITLE_BYTES * 4)
          if child_xml.nil?
            @report[:errors] << "failed to fetch child sitemap #{child_loc}"
            next
          end
          entries.concat(parse_sitemap(child_xml))
        end
        entries
      else
        parse_sitemap(xml)
      end
    end

    def sync_entry(url, lastmod, content_type, now)
      entry = SitemapAutolinkEntry.find_by(url: url)

      if entry.nil?
        title, title_source = resolve_title(url)
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

      changed = lastmod.present? && lastmod != entry.lastmod
      slug_title = entry.title_source == "slug"
      if changed || slug_title
        title, title_source = resolve_title(url)
        if title_source == "page" && title != entry.title
          entry.update!(
            title: title,
            title_source: title_source,
            lastmod: lastmod,
            last_seen_at: now,
          )
          regenerate_terms(entry)
          @report[:title_changed] << url
          return
        end
        entry.update!(lastmod: lastmod, last_seen_at: now)
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

    def resolve_title(url)
      body = @http_get.call(url, MAX_TITLE_BYTES)
      title = body && title_from_html(body)
      return [title, "page"] if title.present?
      [title_from_slug(url), "slug"]
    end

    def title_from_html(html)
      raw =
        html[/<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']/i, 1] ||
          html[/<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:title["']/i, 1] ||
          html[%r{<title[^>]*>([^<]+)</title>}i, 1]
      return nil if raw.nil?
      title = CGI.unescapeHTML(raw).strip
      loop do
        stripped = @title_suffixes.find { |s| s.present? && title.downcase.end_with?(s.downcase) }
        break if stripped.nil?
        title = title[0, title.length - stripped.length].strip
      end
      title.presence
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
    def default_http_get(url, max_bytes, redirects_left = 3)
      uri = URI.parse(url)
      body = +""
      Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: 10,
        read_timeout: 20,
      ) do |http|
        request = Net::HTTP::Get.new(uri, "User-Agent" => USER_AGENT, "Accept" => "text/html,application/xml")
        http.request(request) do |response|
          if response.is_a?(Net::HTTPRedirection) && redirects_left.positive?
            location = response["location"]
            return nil if location.blank?
            return default_http_get(URI.join(url, location).to_s, max_bytes, redirects_left - 1)
          end
          return nil unless response.is_a?(Net::HTTPSuccess)
          response.read_body do |chunk|
            body << chunk
            break if body.bytesize >= max_bytes
            break if body.include?("</title>")
          end
        end
      end
      body
    rescue StandardError
      nil
    end
  end
end
