# frozen_string_literal: true

require "net/http"
require "uri"

module GbfansAutolink
  # Daily catalog synchronization: fetch the configured child sitemaps,
  # diff against the stored entries, resolve titles for new/changed URLs
  # (title fetches happen HERE, never during post cooking), regenerate
  # terms, and report what changed so selective rebakes can be enqueued.
  class SitemapSync
    USER_AGENT = "GBFansAutolinkBot/0.1 (Discourse plugin catalog sync)"
    MAX_TITLE_BYTES = 524_288
    TITLE_SUFFIXES = [
      " - GBFans.com Wiki | GBFans.com",
      " - GBFans.com Wiki",
      " - GBFans.com Shop",
      " | GBFans.com",
      " - GBFans.com",
    ].freeze

    attr_reader :report

    # http_get: injectable ->(url, max_bytes) { body_string_or_nil } for tests.
    def initialize(base_url: nil, sources: nil, http_get: nil)
      @base_url = (base_url || SiteSetting.gbfans_autolink_sitemap_base_url).chomp("/")
      @sources = sources || parse_sources(SiteSetting.gbfans_autolink_sources)
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
        xml = @http_get.call(@base_url + source[:path], MAX_TITLE_BYTES * 4)
        if xml.nil?
          @report[:errors] << "failed to fetch sitemap #{source[:path]}"
          next
        end
        parse_sitemap(xml).each do |loc, lastmod|
          url = GbfansAutolinkEntry.normalize_url(loc.sub(@base_url, ""))
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

    def sync_entry(url, lastmod, content_type, now)
      entry = GbfansAutolinkEntry.find_by(url: url)

      if entry.nil?
        title, title_source = resolve_title(url)
        entry =
          GbfansAutolinkEntry.create!(
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
      GbfansAutolinkEntry
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
        .where(origin: GbfansAutolinkTerm.origins[:generated])
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
      body = @http_get.call(@base_url + url, MAX_TITLE_BYTES)
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
        stripped = TITLE_SUFFIXES.find { |s| title.downcase.end_with?(s.downcase) }
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
        .split(%r{</url>}i)
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
          path, type = row.split(",").map(&:strip)
          { path: path, type: type.presence || "content" } if path.present?
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
