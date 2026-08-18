# frozen_string_literal: true

# JSON management API for the autolink catalog. Staff only (routes are
# mounted under the admin namespace with StaffConstraint).
#
#   GET    /admin/plugins/discourse-sitemap-autolink/status
#   GET    /admin/plugins/discourse-sitemap-autolink/entries?q=&type=&enabled=&page=
#   POST   /admin/plugins/discourse-sitemap-autolink/entries      (manual entry)
#   PUT    /admin/plugins/discourse-sitemap-autolink/entries/:id  (enable/priority/url…)
#   GET    /admin/plugins/discourse-sitemap-autolink/terms?q=&state=&type=&origin=&page=
#   POST   /admin/plugins/discourse-sitemap-autolink/terms        (add alias)
#   PUT    /admin/plugins/discourse-sitemap-autolink/terms/bulk   (ids= or filter[…]=)
#   PUT    /admin/plugins/discourse-sitemap-autolink/terms/:id    (approve/disable…)
#   DELETE /admin/plugins/discourse-sitemap-autolink/terms/:id
#   DELETE /admin/plugins/discourse-sitemap-autolink/entries/purge  (filter[…]=)
#   DELETE /admin/plugins/discourse-sitemap-autolink/entries/:id  (purge one)
#   GET    /admin/plugins/discourse-sitemap-autolink/sitemaps/list
#   PUT    /admin/plugins/discourse-sitemap-autolink/sitemaps/:id (status=)
#   POST   /admin/plugins/discourse-sitemap-autolink/sitemaps/discover
#   GET    /admin/plugins/discourse-sitemap-autolink/collisions?q=&page=
#   POST   /admin/plugins/discourse-sitemap-autolink/collisions/resolve
#   GET    /admin/plugins/discourse-sitemap-autolink/overlaps?q=&page=
#   POST   /admin/plugins/discourse-sitemap-autolink/sync
#   POST   /admin/plugins/discourse-sitemap-autolink/rebuild
#   POST   /admin/plugins/discourse-sitemap-autolink/rebake       (phrase= or all=true)
#
# Every list endpoint pages: a catalog with thousands of URLs behind it
# has tens of thousands of phrases, and no view may try to hold them
# all. The review queue is `terms?state=pending_review`.
class SitemapAutolinkAdminController < Admin::AdminController
  requires_plugin SitemapAutolink::PLUGIN_NAME

  PAGE_SIZE = 50

  # A bulk state change addresses either an explicit id list (what the
  # page has on screen) or a whole filter (what the admin is looking
  # at, which may be thousands of rows).
  MAX_BULK_IDS = 1000

  # The overlap report walks every keyword through an automaton built
  # from every keyword. This caps the RESPONSE — how many pairs may be
  # listed — not the work, which is linear in total keyword length and
  # happens whatever the cap says. Pairs suppressed for pointing at the
  # same page deliberately do not count toward it: they are the bulk of
  # a real catalog, and counting them would trip the cap before the
  # overlaps worth reading had been found.
  MAX_OVERLAP_PAIRS = 5000

  def status
    last_run = SitemapAutolinkSyncRun.recent.first
    stats = catalog_stats
    render json: {
             enabled: SiteSetting.sitemap_autolink_enabled,
             sync_enabled: SiteSetting.sitemap_autolink_sync_enabled,
             sources_configured: SiteSetting.sitemap_autolink_sources.present?,
             catalog_version: SitemapAutolink::Catalog.version,
             # These predate `stats` and are kept for callers built
             # against them — but READ from it rather than re-queried.
             # Asking the database the same five questions twice per
             # page load was pure waste, and two answers that could
             # disagree is worse than one.
             active_rules: stats[:rules],
             entries: stats[:pages][:total],
             active_entries: stats[:pages][:live],
             terms: stats[:keywords][:total],
             pending_terms: stats[:keywords][:pending_review],
             entry_types: entry_types,
             # Child sitemaps discovered but not yet approved. Nothing
             # from them is imported, which is easy to mistake for a
             # broken sync unless the overview says so.
             pending_sitemaps: stats[:sitemaps][:pending],
             enabled_types_setting: SiteSetting.sitemap_autolink_enabled_types,
             stats: stats,
             last_run: last_run && serialize_run(last_run),
           }
  end

  # Durable audit trail of sitemap synchronizations.
  def runs
    render json: {
             runs: SitemapAutolinkSyncRun.recent.limit(30).map { |r| serialize_run(r) },
           }
  end

  # Dry run against the real sitemaps: nothing is written. Returns what
  # WOULD be ingested — URL counts, pattern exclusions, resolved titles
  # and the phrases each title generates (with review states).
  def preview
    if SiteSetting.sitemap_autolink_sources.blank?
      render json: failed_json.merge(error: "configure sitemap_autolink_sources first"),
             status: :unprocessable_content
      return
    end
    limit = (params[:limit] || 10).to_i.clamp(1, 50)
    render json: SitemapAutolink::SitemapSync.new.preview(limit_per_source: limit)
  end

  # The catalog, grouped the way it is managed: one page with all of its
  # keywords, not one row per keyword. The question an admin actually
  # asks is "what points at THIS url" — so a search for a phrase returns
  # the page that owns it, with its whole phrase list intact.
  def entries
    scope = SitemapAutolinkEntry.includes(:terms, :sitemaps).order(:url)
    scope = scope.where(content_type: params[:type]) if params[:type].present?
    scope = scope.where(enabled: params[:enabled] == "true") if params[:enabled].present?
    if params[:q].present?
      q = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q])}%"
      scope =
        scope.where(
          "sitemap_autolink_entries.url ILIKE :q OR sitemap_autolink_entries.title ILIKE :q " \
            "OR EXISTS (SELECT 1 FROM sitemap_autolink_terms " \
            "WHERE sitemap_autolink_terms.entry_id = sitemap_autolink_entries.id " \
            "AND (sitemap_autolink_terms.phrase ILIKE :q " \
            "OR sitemap_autolink_terms.normalized_phrase ILIKE :q))",
          q: q,
        )
    end
    if params[:state].present?
      scope =
        scope.where(
          id: SitemapAutolinkTerm.where(state: validated_state(params[:state])).select(:entry_id),
        )
    end
    scope = scope.where(id: entry_ids_in_sitemap(params[:sitemap])) if params[:sitemap].present?
    scope = apply_page_state(scope, params[:page_state])
    page = current_page
    total = scope.count
    records = scope.offset(page * PAGE_SIZE).limit(PAGE_SIZE).to_a
    duplicates = duplicate_phrases(records)
    render json: {
             total: total,
             page: page,
             per_page: PAGE_SIZE,
             pages: page_count(total),
             types: entry_types,
             sitemaps: entry_sitemaps,
             # Phrase counts, not page counts: the state filters and the
             # bulk actions beside them both act on phrases, and they
             # must agree about how many.
             state_counts: state_counts(term_scope(params)),
             # A keyword's state says it passed review. Whether it LINKS
             # also depends on its page still being live, and the two
             # come apart constantly — a page filtered out of the
             # sitemap keeps every one of its auto-active keywords.
             # Reporting only the state would call those active.
             linking_count: linking_count(params),
             # How many of the matching pages are gone from the sitemap:
             # the count the purge button names before it deletes them.
             gone_pages: scope.gone.count,
             entries: records.map { |e| serialize_entry(e, duplicates: duplicates) },
           }
  end

  # The phrase-first view of the catalog: one row per keyword with the
  # destination it points at. This is where a thousands-of-phrases
  # catalog is actually managed, so it pages, searches phrase text as
  # well as destination, and reports how the whole filtered set breaks
  # down by state (`state_counts`) — the counts the review queue and
  # the state filters are built from.
  def terms
    unfiltered_by_state = term_scope(params)
    scope = unfiltered_by_state
    scope = scope.where(state: validated_state(params[:state])) if params[:state].present?

    page = current_page
    total = scope.count
    records =
      scope
        .preload(:entry)
        .order("sitemap_autolink_terms.normalized_phrase", "sitemap_autolink_terms.id")
        .offset(page * PAGE_SIZE)
        .limit(PAGE_SIZE)
    render json: {
             total: total,
             page: page,
             per_page: PAGE_SIZE,
             pages: page_count(total),
             types: entry_types,
             state_counts: state_counts(unfiltered_by_state),
             terms: records.map { |t| serialize_term(t, entry: t.entry) },
           }
  end

  # Bulk state change for terms: either an explicit id list, or every
  # term matching a filter (`filter[q]`, `filter[state]`, `filter[type]`,
  # `filter[origin]`). Clearing a review queue of thousands of phrases
  # 50 rows at a time is not review, it is data entry — so the page can
  # act on the whole filter it is showing, having named the count first.
  def bulk_terms
    state = validated_state(params.require(:state))
    scope =
      if params[:filter].present?
        SitemapAutolinkTerm.where(
          id: filtered_bulk_scope.select("sitemap_autolink_terms.id"),
        )
      else
        SitemapAutolinkTerm.where(id: Array(params[:ids]).map(&:to_i).first(MAX_BULK_IDS))
      end
    updated =
      scope.update_all(state: SitemapAutolinkTerm.states[state], updated_at: Time.zone.now)
    bump
    render json: success_json.merge(updated: updated)
  end

  def create_entry
    entry =
      SitemapAutolinkEntry.create!(
        url: SitemapAutolinkEntry.normalize_url(params.require(:url)),
        title: params.require(:title),
        content_type: params[:content_type].presence || "content",
        source: "manual",
        title_source: "manual",
        auto_discovered: false,
        first_seen_at: Time.zone.now,
        last_seen_at: Time.zone.now,
      )
    bump
    render json: serialize_entry(entry)
  end

  def update_entry
    entry = SitemapAutolinkEntry.find(params[:id])
    changes = {}
    if params.key?(:enabled)
      # Accept boolean true/false from JSON clients as well as the
      # "true"/"false" strings the admin UI sends — a bare `== "true"`
      # would silently DISABLE an entry for a JSON `enabled: true`.
      changes[:enabled] = ActiveModel::Type::Boolean.new.cast(params[:enabled]) || false
    end
    changes[:priority] = params[:priority].presence&.to_i if params.key?(:priority)
    changes[:url] = SitemapAutolinkEntry.normalize_url(params[:url]) if params[:url].present?
    changes[:title] = params[:title] if params[:title].present?
    entry.update!(changes)
    bump
    render json: serialize_entry(entry.reload)
  end

  # Every sitemap the plugin knows about: the configured sources, and
  # the children found inside any of them that is an index.
  #
  # This exists because "pull from these sitemaps" was never enough
  # information. Pointing at an index silently expanded to whatever it
  # listed, and children holding tens of thousands of URLs got imported
  # with no warning and no opportunity to decline. Here each one is a row
  # with its size, so the decision is made with the number in hand.
  def sitemaps
    records = SitemapAutolinkSitemap.all.to_a
    totals = SitemapAutolinkEntrySitemap.group(:sitemap_id).count
    live =
      SitemapAutolinkEntrySitemap
        .joins(:entry)
        .merge(SitemapAutolinkEntry.active)
        .group(:sitemap_id)
        .count
    gone =
      SitemapAutolinkEntrySitemap
        .joins(:entry)
        .merge(SitemapAutolinkEntry.gone)
        .group(:sitemap_id)
        .count
    # Each configured source immediately followed by its own children,
    # so the page reads as the tree it actually is.
    records.sort_by! { |r| [r.parent_url.presence || r.url, r.parent_url.present? ? 1 : 0, r.url] }
    children = records.group_by(&:parent_url)
    render json: {
             sitemaps:
               records.map do |record|
                 serialize_sitemap(
                   record,
                   entries: totals[record.id] || 0,
                   live: live[record.id] || 0,
                   gone: gone[record.id] || 0,
                   children: children[record.url] || [],
                 )
               end,
             pending: records.count { |r| r.status == SitemapAutolinkSitemap::PENDING },
             configured_sources: SiteSetting.sitemap_autolink_sources.split("|").map(&:strip),
             auto_import: SiteSetting.sitemap_autolink_auto_import_new_sitemaps,
           }
  end

  # Read the configured sources and record what they list, WITHOUT
  # importing anything. Bounded by its own budget because it runs inside
  # this request.
  def discover_sitemaps
    if SiteSetting.sitemap_autolink_sources.blank?
      render json: failed_json.merge(error: "configure sitemap_autolink_sources first"),
             status: :unprocessable_content
      return
    end
    report = SitemapAutolink::SitemapSync.new.discover!
    render json:
             success_json.merge(
               errors: report[:errors],
               notes: report[:notes],
               pending: report[:pending_sitemaps],
             )
  end

  # Approve a sitemap for import, or decline it.
  #
  # Turning one OFF detaches its URLs there and then, rather than
  # leaving them to look imported until the next sync: anything that was
  # listed ONLY there is marked gone immediately, and `purge=true`
  # deletes those outright.
  def update_sitemap
    record = SitemapAutolinkSitemap.find(params[:id])
    status = params.require(:status).to_s
    raise Discourse::InvalidParameters.new(:status) if !SitemapAutolinkSitemap.valid_status?(status)

    result = { orphaned: 0, purged: 0 }
    was_importing = record.status == SitemapAutolinkSitemap::ENABLED
    record.update!(status: status)
    if was_importing && status != SitemapAutolinkSitemap::ENABLED
      result = detach_sitemap!(record, purge: params[:purge] == "true")
    end
    bump
    record.reload
    render json:
             serialize_sitemap(
               record,
               entries: record.entry_sitemaps.count,
               # An index's row is mostly its child counts; returning
               # zeros here told a scripted caller it had none.
               children: SitemapAutolinkSitemap.where(parent_url: record.url).to_a,
             ).merge(result)
  end

  # Hard-delete every page matching the current filter that is gone from
  # the sitemap.
  #
  # Everything else in this plugin is reversible — a page that vanishes
  # is disabled, keeps its keywords and comes back by itself if the URL
  # returns. That is the right default and the wrong only option: a
  # catalog that has been re-pointed at different sitemaps accumulates
  # dead pages that will never return, and there was no way to be rid of
  # them. Purged pages are forgotten completely, so a URL that does turn
  # up again is ingested as a brand new page.
  def purge_entries
    scope = SitemapAutolinkEntry.gone
    scope = scope.where(content_type: params.dig(:filter, :type)) if params.dig(:filter, :type).present?
    if params.dig(:filter, :sitemap).present?
      scope = scope.where(id: entry_ids_in_sitemap(params.dig(:filter, :sitemap)))
    end
    if params.dig(:filter, :q).present?
      q = "%#{ActiveRecord::Base.sanitize_sql_like(params.dig(:filter, :q))}%"
      scope = scope.where("url ILIKE :q OR title ILIKE :q", q: q)
    end
    purged = purge_entry_ids!(scope.pluck(:id))
    bump
    render json: success_json.merge(purged: purged)
  end

  # Purge one page, from its card.
  #
  # Only a page that is GONE from the sitemap may be deleted. A page
  # still listed in one would be re-ingested by the next sync, so
  # deleting it is not a thing that can succeed — the honest control for
  # a live page is Disable, and the API says so rather than performing a
  # deletion that quietly undoes itself.
  def destroy_entry
    entry = SitemapAutolinkEntry.find(params[:id])
    if !entry.removed_from_source
      render json:
               failed_json.merge(
                 error:
                   "#{entry.url} is still listed in a sitemap — disable it instead. " \
                     "Only pages gone from the sitemap can be deleted.",
               ),
             status: :unprocessable_content
      return
    end
    purge_entry_ids!([entry.id])
    bump
    render json: success_json
  end

  def create_term
    entry = SitemapAutolinkEntry.find(params.require(:entry_id))
    term =
      entry.terms.create!(
        phrase: params.require(:phrase),
        origin: :manual,
        state: validated_state(params[:state].presence || "approved"),
      )
    bump
    render json: serialize_term(term)
  end

  def update_term
    term = SitemapAutolinkTerm.find(params[:id])
    term.update!(state: validated_state(params.require(:state)))
    bump
    render json: serialize_term(term)
  end

  def destroy_term
    SitemapAutolinkTerm.find(params[:id]).destroy!
    bump
    render json: success_json
  end

  # Every phrase that two or more pages both actually link.
  #
  # "Claimed twice" is not a conflict. A page whose keyword is disabled,
  # or that is switched off, or that has dropped out of the sitemap, has
  # already lost the phrase — listing it beside the page that won is
  # noise, and at catalog scale it is most of the report. So the default
  # lists only phrases where more than one candidate compiles into a
  # live rule. `include_inactive=true` adds the settled ones back, which
  # is what you want when the question is "why is THIS page not
  # linking".
  #
  # Detection still runs over every term rather than a pre-filtered
  # scope: narrowing the query hid the losing candidates entirely, and
  # the losers are what makes a contest legible.
  def collisions
    winners = compiled_winners
    scope = SitemapAutolinkTerm.all
    if params[:q].present?
      scope =
        scope.where(
          "sitemap_autolink_terms.normalized_phrase ILIKE :q",
          q: "%#{ActiveRecord::Base.sanitize_sql_like(params[:q])}%",
        )
    end
    duplicated =
      scope.group(:normalized_phrase).having("COUNT(DISTINCT entry_id) > 1").pluck(
        :normalized_phrase,
      )

    # One query for every candidate of every duplicated phrase, then the
    # competing-count filter and the page slice happen in Ruby — both
    # need `linking`, which no single column holds.
    candidates_by_phrase =
      SitemapAutolinkTerm
        .joins(:entry)
        .where(normalized_phrase: duplicated)
        .pluck(
          "sitemap_autolink_terms.normalized_phrase",
          "sitemap_autolink_terms.id",
          "sitemap_autolink_entries.id",
          "sitemap_autolink_entries.url",
          "sitemap_autolink_entries.title",
          "sitemap_autolink_entries.content_type",
          "sitemap_autolink_terms.state",
          "sitemap_autolink_entries.enabled",
          "sitemap_autolink_entries.removed_from_source",
        )
        .group_by(&:first)

    reports =
      duplicated.sort.map do |phrase|
        rule = winners[phrase]
        winner = rule && rule[:url]
        # A rule compiled from the manual-mappings SETTING carries no
        # entry id. When the setting owns a phrase it beats every page
        # claiming it, so this is not a contest between pages and
        # nothing an admin does here would change a link.
        overridden = rule.present? && rule[:entry_id].nil?
        candidates =
          (candidates_by_phrase[phrase] || []).map do |row|
            _p, term_id, entry_id, url, title, type, state, enabled, removed = row
            name = SitemapAutolinkTerm.state_name(state)
            linking = linking_pairs.include?([phrase, entry_id]) && !overridden
            {
              term_id: term_id,
              entry_id: entry_id,
              url: url,
              title: title,
              type: type,
              state: name,
              page_state: page_state_name(enabled, removed),
              linking: linking,
              reason:
                not_linking_reason(
                  state: name,
                  enabled: enabled,
                  removed: removed,
                  linking: linking,
                  url: url,
                  overridden: overridden,
                ),
              # Whether handing it this phrase would actually make it
              # link. The button is only worth offering where it is.
              can_win: !overridden && enabled && !removed,
              winner: linking && url == winner,
            }
          end
        {
          phrase: phrase,
          winner: winner,
          linking_candidates: candidates.count { |c| c[:linking] },
          candidates: candidates,
        }
      end

    contested = reports.count { |r| r[:linking_candidates] > 1 }
    # Counted BEFORE the filter runs: afterwards `reports` holds only the
    # contested ones, and the difference would always be zero.
    settled = reports.size - contested
    show_all = params[:include_inactive] == "true"
    reports.select! { |r| r[:linking_candidates] > 1 } if !show_all

    page = current_page
    render json: {
             total: reports.size,
             page: page,
             per_page: PAGE_SIZE,
             pages: page_count(reports.size),
             competing: contested,
             settled: settled,
             include_inactive: show_all,
             collisions: reports[page * PAGE_SIZE, PAGE_SIZE] || [],
           }
  end

  # Hand one contested phrase to one page.
  #
  # The edit is scoped to the phrase, not the page: dropping a page's
  # priority number would hand it every OTHER keyword it shares as well,
  # which is never what "this page should win this phrase" means.
  # Disabling the phrase on the losing pages is the narrow change, and
  # the keywords page can put any of them back.
  def resolve_collision
    phrase = SitemapAutolink::Matcher.normalize(params.require(:phrase).to_s)
    winner = SitemapAutolinkTerm.find_by(normalized_phrase: phrase, entry_id: params[:entry_id])
    if winner.nil?
      render json: failed_json.merge(error: "that page does not claim #{phrase}"),
             status: :not_found
      return
    end

    # Refused up front, not reported after the fact.
    #
    # Handing the phrase to a page that cannot link it disables it on
    # every page that CAN, leaving the phrase linking nowhere at all —
    # the exact opposite of what the button says, with the damage
    # already durable by the time a "nothing links now" notice reaches
    # the admin. Both refusals name the thing to fix instead.
    entry = winner.entry
    if entry.removed_from_source || !entry.enabled
      render json:
               failed_json.merge(
                 error:
                   "#{entry.url} is #{entry.removed_from_source ? "gone from the sitemap" : "disabled"}, " \
                     "so giving it \"#{phrase}\" would leave the keyword linking nowhere. " \
                     "Put the page back first.",
               ),
             status: :unprocessable_content
      return
    end
    if phrase_owned_by_setting?(phrase)
      render json:
               failed_json.merge(
                 error:
                   "sitemap_autolink_manual_mappings already claims \"#{phrase}\" and outranks every " \
                     "page here, so this would change no link. Edit that setting instead.",
               ),
             status: :unprocessable_content
      return
    end

    # Already-disabled claimants are left out of the count rather than
    # rewritten, so the number reported back is what actually changed.
    losers =
      SitemapAutolinkTerm
        .where(normalized_phrase: phrase)
        .where.not(entry_id: winner.entry_id)
        .where.not(state: SitemapAutolinkTerm.states[:disabled])
    disabled = 0
    # One transaction: a half-applied resolve leaves the phrase disabled
    # everywhere with no winner named.
    SitemapAutolinkTerm.transaction do
      # Naming a winner that was itself awaiting review or disabled has
      # to approve it, and it happens FIRST so a failure here cannot
      # leave the losers already disabled.
      if !SitemapAutolinkTerm::LINKABLE_STATES.include?(winner.state)
        winner.update!(state: :approved)
      end
      disabled =
        losers.update_all(state: SitemapAutolinkTerm.states[:disabled], updated_at: Time.zone.now)
    end
    bump
    render json: success_json.merge(disabled: disabled, winner: serialize_term(winner))
  end

  # Keywords that sit inside a longer keyword AND lead somewhere else.
  #
  # "Acme Widget Kit Gasket Set" contains "Widget Kit" and "Gasket Set".
  # Wherever the long one appears it takes the whole span, so the short
  # ones do not fire there — which only matters if a short one would
  # have gone to a different page.
  #
  # Most contained pairs do not: a page titled "Acme Widget Kit Gasket
  # Set" generates its own sub-phrases, so every one of them already
  # points at that same page and the reader lands in the same place
  # whichever fires. Those are not listed at all — only counted, so the
  # omission is visible.
  #
  # A real overlap is two different destinations sharing words: "Widget
  # Kit" pointing at a documentation page while "Deluxe Widget Kit"
  # points at a shop listing. Which one a post gets then depends on how
  # much of the phrase its author typed.
  #
  # Detection runs over the WHOLE catalog, not the compiled ruleset. The
  # ruleset holds one rule per phrase — so sourcing the report from it
  # hid exactly the overlaps worth seeing: a keyword still awaiting
  # review, or one on a page someone disabled, silently had none.
  def overlaps
    owners = Hash.new { |all, phrase| all[phrase] = [] }
    SitemapAutolinkTerm
      .joins(:entry)
      .pluck(
        "sitemap_autolink_terms.normalized_phrase",
        "sitemap_autolink_entries.id",
        "sitemap_autolink_entries.url",
        "sitemap_autolink_entries.title",
        "sitemap_autolink_entries.content_type",
        "sitemap_autolink_terms.state",
        "sitemap_autolink_entries.enabled",
        "sitemap_autolink_entries.removed_from_source",
      )
      .each do |phrase, entry_id, url, title, type, state, enabled, removed|
        name = SitemapAutolinkTerm.state_name(state)
        linking = linking_pairs.include?([phrase, entry_id])
        owners[phrase] << {
          entry_id: entry_id,
          url: url,
          title: title,
          type: type,
          state: name,
          page_state: page_state_name(enabled, removed),
          linking: linking,
          reason:
            not_linking_reason(
              state: name,
              enabled: enabled,
              removed: removed,
              linking: linking,
              url: url,
            ),
        }
      end

    winners = compiled_winners
    # Where a phrase actually sends a reader: the compiled winner while
    # it links, otherwise every page claiming it. Two phrases with the
    # same destination cannot take a link away from each other.
    #
    # Unlike the conflict report, a phrase the manual-mappings setting
    # owns is NOT written off here. An overlap is about where the two
    # phrases LEAD, and the winner below is already the setting's URL —
    # so the comparison stays honest without special-casing it.
    destinations = {}
    destination =
      lambda do |phrase|
        destinations[phrase] ||= begin
          rule = winners[phrase]
          rule ? [rule[:url]] : owners[phrase].map { |o| o[:url] }.uniq.sort
        end
      end

    # One automaton over every distinct keyword, then each keyword is
    # scanned through it: whatever else it contains — on word
    # boundaries, so "kit" is not found inside "kitbash" — is a keyword
    # it swallows. Linear in total keyword length; ~100 ms at 7,500.
    show_all = params[:include_inactive] == "true"
    matcher = SitemapAutolink::Matcher.new(owners.keys.map { |phrase| { phrase: phrase } })
    covered_by = Hash.new { |shadowed, phrase| shadowed[phrase] = [] }
    truncated = false
    pairs = 0
    same_destination = 0
    owners.each_key do |long|
      # `scan` reports every OCCURRENCE, and a keyword can sit inside a
      # longer one twice. The pair is still one pair — counting it twice
      # inflated both the reported figures and the cap below.
      seen = Set.new
      matcher
        .scan(long)
        .each do |candidate|
          inner = candidate[:rule][:phrase]
          next if inner == long
          next if !seen.add?(inner)
          if destination.call(inner) == destination.call(long)
            same_destination += 1
            # Counted, and listed too when the admin asks to see what is
            # already settled — otherwise "my short keyword never fires"
            # had an aggregate number and no way to reach the rows
            # behind it.
            next if !show_all
          end
          covered_by[inner] << long
          pairs += 1
        end
      if pairs >= MAX_OVERLAP_PAIRS
        truncated = true
        break
      end
    end

    linking = ->(phrase) { owners[phrase].any? { |o| o[:linking] } }
    phrases = covered_by.keys
    if params[:q].present?
      needle = SitemapAutolink::Matcher.normalize(params[:q].to_s)
      phrases =
        phrases.select do |phrase|
          phrase.include?(needle) || covered_by[phrase].any? { |long| long.include?(needle) }
        end
    end
    # An overlap only changes what links when both keywords are live.
    settled = 0
    if !show_all
      live = phrases.select { |phrase| linking.call(phrase) && covered_by[phrase].any?(&linking) }
      settled = phrases.size - live.size
      phrases = live
    end
    phrases.sort!

    page = current_page
    render json: {
             total: phrases.size,
             page: page,
             per_page: PAGE_SIZE,
             pages: page_count(phrases.size),
             truncated: truncated,
             # Measured over the whole catalog, before any search — so
             # it is withheld rather than printed beside a filtered list
             # it does not describe.
             same_destination: params[:q].present? ? nil : same_destination,
             settled: settled,
             include_inactive: show_all,
             overlaps:
               (phrases[page * PAGE_SIZE, PAGE_SIZE] || []).map do |phrase|
                 {
                   phrase: phrase,
                   linking: linking.call(phrase),
                   owners: owners[phrase],
                   covered_by:
                     covered_by[phrase].uniq.sort.map do |long|
                       { phrase: long, linking: linking.call(long), owners: owners[long] }
                     end,
                 }
               end,
           }
  end

  def sync
    if Discourse.redis.get(SitemapAutolink::SitemapSync::RUNNING_LOCK_KEY).present?
      return(
        render json:
                 failed_json.merge(
                   error: "A synchronization is already running — cancel it or wait for it to finish.",
                 ),
               status: :conflict
      )
    end
    # A deliberate Sync now lifts any lingering admin cancel.
    SitemapAutolink::SitemapSync.clear_cancel!
    Jobs.enqueue(:sitemap_autolink_sync, triggered_by: "manual")
    render json: success_json
  end

  def cancel_sync
    SitemapAutolink::SitemapSync.request_cancel!
    render json: success_json
  end

  def rebuild
    bump
    render json: success_json.merge(catalog_version: SitemapAutolink::Catalog.version)
  end

  def rebake
    if params[:all] == "true"
      # Candidate-filtered catch-up wave: every post that may contain
      # any active phrase, in throttled batches. An unconditional
      # full-forum rebake stays with Discourse's rake posts:rebake.
      Jobs.enqueue(:sitemap_autolink_rebake_posts, all_phrases: true)
      render json: success_json
    elsif params[:phrase].present?
      Jobs.enqueue(:sitemap_autolink_rebake_posts, phrases: [params[:phrase]])
      render json: success_json
    else
      render json: failed_json, status: :unprocessable_content
    end
  end

  private

  def current_page
    params[:page].to_i.clamp(0, 10_000)
  end

  # Terms first, then memberships, then the entries themselves: three
  # statements instead of the per-row cascade `destroy_all` would issue,
  # because a purge routinely addresses thousands of rows from inside a
  # web request.
  def purge_entry_ids!(ids)
    ids = Array(ids)
    return 0 if ids.empty?
    SitemapAutolinkTerm.where(entry_id: ids).delete_all
    SitemapAutolinkEntrySitemap.where(entry_id: ids).delete_all
    SitemapAutolinkEntry.where(id: ids).delete_all
  end

  # Detach every URL this sitemap was carrying. Whatever is left with no
  # sitemap at all is gone from the source by definition and says so
  # straight away instead of after the next sync.
  def detach_sitemap!(record, purge: false)
    entry_ids = SitemapAutolinkEntrySitemap.where(sitemap_id: record.id).pluck(:entry_id)
    SitemapAutolinkEntrySitemap.where(sitemap_id: record.id).delete_all
    return { orphaned: 0, purged: 0 } if entry_ids.empty?
    orphan_ids =
      SitemapAutolinkEntry
        .where(id: entry_ids, source: "sitemap")
        .where.not(id: SitemapAutolinkEntrySitemap.select(:entry_id))
        .pluck(:id)
    return { orphaned: 0, purged: 0 } if orphan_ids.empty?
    return { orphaned: orphan_ids.size, purged: purge_entry_ids!(orphan_ids) } if purge
    SitemapAutolinkEntry.where(id: orphan_ids).update_all(removed_from_source: true)
    { orphaned: orphan_ids.size, purged: 0 }
  end

  def entry_ids_in_sitemap(url)
    SitemapAutolinkEntrySitemap.where(
      sitemap_id: SitemapAutolinkSitemap.where(url: url).select(:id),
    ).select(:entry_id)
  end

  # The numbers the overview is for. A one-line summary answered none of
  # the questions an admin opens the page with — how much of the catalog
  # is live, how much is waiting on them, how much has fallen out of the
  # sitemaps — so it reports each of them.
  #
  # Cost: a handful of counts plus one pass over the compiled rules
  # (shared with the conflict count through the memoized
  # `linking_pairs`, so the rules are built once per request). Two of
  # the counts — `auto_discovered` and term `origin` — have no index
  # and are sequential scans; at catalog scale that is sub-millisecond,
  # and an index existing only to serve an admin figure would cost more
  # than it saves on every write.
  #
  # The overlap report is deliberately NOT among these: it builds an
  # automaton over every keyword, which belongs on the page that asks
  # for it.
  def catalog_stats
    terms = state_counts(SitemapAutolinkTerm.all)
    sitemaps = SitemapAutolinkSitemap.group(:status).count
    {
      pages: {
        total: SitemapAutolinkEntry.count,
        live: SitemapAutolinkEntry.active.count,
        disabled: SitemapAutolinkEntry.where(enabled: false, removed_from_source: false).count,
        gone: SitemapAutolinkEntry.gone.count,
        manual: SitemapAutolinkEntry.where(auto_discovered: false).count,
        by_type: SitemapAutolinkEntry.active.group(:content_type).count,
      },
      # The four states, which do add up to the total. An earlier cut
      # dropped auto_active — the state most generated keywords are in —
      # and put a count of keyword/page PAIRS beside per-keyword counts,
      # so the group could not be reconciled by anyone reading it.
      keywords: {
        total: SitemapAutolinkTerm.count,
        auto_active: terms["auto_active"],
        approved: terms["approved"],
        pending_review: terms["pending_review"],
        disabled: terms["disabled"],
        manual: SitemapAutolinkTerm.manual.count,
      },
      # Distinct phrases that link (one rule per phrase after collision
      # resolution), and how many of them more than one live page is
      # still fighting over.
      rules: SitemapAutolink::Catalog.ruleset.size,
      contested: contested_phrase_count,
      sitemaps: {
        # An index imports nothing itself — the model says so with its
        # own `importing` scope — so counting one here would contradict
        # the Sitemaps page sitting one click away.
        imported: SitemapAutolinkSitemap.importing.count,
        pending: sitemaps[SitemapAutolinkSitemap::PENDING] || 0,
        ignored: sitemaps[SitemapAutolinkSitemap::IGNORED] || 0,
        indexes: SitemapAutolinkSitemap.where(kind: SitemapAutolinkSitemap::INDEX).count,
      },
    }
  end

  # Phrases more than one live page links — the same question the
  # conflicts report answers, computed the same way, because a headline
  # figure that disagrees with the page it links to is worse than no
  # figure. Both sides read `linking_pairs` (which applies the URL check
  # compilation applies) and both discount a phrase the manual-mappings
  # setting has claimed.
  def contested_phrase_count
    linking_pairs
      .group_by(&:first)
      .count { |phrase, pairs| pairs.size > 1 && !phrase_owned_by_setting?(phrase) }
  end

  # Every (phrase, entry id) pair that actually compiles into a linking
  # rule.
  #
  # Taken from the catalog's own rule builder rather than re-derived
  # here. "Does this link?" is not one column: it needs the term's
  # state, whether the page is enabled, whether it is still in a
  # sitemap, the enabled-types list, the excluded-terms list and the
  # excluded-URL patterns — and a second copy of that list is how the
  # conflict reports drifted from what the forum really links and began
  # calling settled questions conflicts.
  def linking_pairs
    @linking_pairs ||=
      SitemapAutolink::Catalog
        .database_rules
        # Compilation drops rules whose URL is not a plainly safe shape,
        # and a hand-created entry is the one place an unsafe one can
        # come from. Without this the report would call such a page a
        # live rival for a phrase it can never link.
        .select { |r| SitemapAutolink::Ruleset.safe_url?(r[:url]) }
        .map { |r| [r[:phrase], r[:entry_id]] }
        .to_set
  end

  # Rules compiled from the manual-mappings SETTING carry no entry id.
  # When one wins a phrase it outranks every page claiming it, so no
  # catalog page links that phrase and no edit made in the conflict
  # report would change one.
  def compiled_winners
    @compiled_winners ||= SitemapAutolink::Catalog.ruleset.rules.index_by { |r| r[:phrase] }
  end

  def phrase_owned_by_setting?(phrase)
    rule = compiled_winners[phrase]
    rule.present? && rule[:entry_id].nil?
  end

  # Why a page is out of the running, which is the first thing asked of
  # a candidate that is not linking.
  def page_state_name(enabled, removed)
    return "removed" if removed
    return "disabled" if !enabled
    "live"
  end

  # The single reason a candidate is not linking, decided here rather
  # than inferred in the template from a state name.
  #
  # The last two branches are the ones that matter. A term can be
  # approved, on a live page, and still compile into nothing — because
  # the manual-mappings setting claimed the phrase, or because the
  # enabled-types list, the excluded-terms list or an excluded URL
  # pattern rules it out. Falling back to the term's own state there
  # printed "keyword approved" as the reason it was not linking, which
  # answers nothing and reads as a contradiction.
  def not_linking_reason(state:, enabled:, removed:, linking:, url: nil, overridden: false)
    return nil if linking
    return "page_gone" if removed
    return "page_disabled" if !enabled
    return "keyword_disabled" if state == "disabled"
    return "keyword_pending" if state == "pending_review"
    return "override" if overridden
    # A URL that could never become a link is the page's own problem,
    # not a setting's — sending the admin to check three exclusion
    # lists that say nothing about it wastes the trip.
    return "unlinkable_url" if url.present? && !SitemapAutolink::Ruleset.safe_url?(url)
    "settings"
  end

  def page_count(total)
    (total.to_f / PAGE_SIZE).ceil
  end

  def entry_types
    SitemapAutolinkEntry.distinct.order(:content_type).pluck(:content_type)
  end

  # Only sitemaps that actually produced entries. Rows ingested before
  # membership was recorded have none, and appear under "all" until a
  # sync sees their URL again.
  def entry_sitemaps
    SitemapAutolinkSitemap
      .where(id: SitemapAutolinkEntrySitemap.select(:sitemap_id))
      .order(:url)
      .pluck(:url)
  end

  def serialize_sitemap(record, entries: 0, live: 0, gone: 0, children: [])
    {
      id: record.id,
      url: record.url,
      parent_url: record.parent_url,
      content_type: record.content_type,
      kind: record.kind,
      status: record.status,
      configured: record.configured,
      url_count: record.url_count,
      url_count_partial: record.url_count_partial,
      last_seen_at: record.last_seen_at,
      last_fetched_at: record.last_fetched_at,
      last_error: record.last_error,
      entries: entries,
      live_entries: live,
      gone_entries: gone,
      # An index imports nothing itself — the decision is one per child,
      # so the row reports how those decisions stand instead of leaving
      # the admin to count indented rows.
      children: children.size,
      children_imported: children.count { |c| c.status == SitemapAutolinkSitemap::ENABLED },
      children_pending: children.count { |c| c.status == SitemapAutolinkSitemap::PENDING },
      children_ignored: children.count { |c| c.status == SitemapAutolinkSitemap::IGNORED },
    }
  end

  # A page is "live" only when it is both enabled and still in the
  # sitemap; those are separate columns and the difference matters, so
  # the filter names them separately rather than offering one on/off.
  def apply_page_state(scope, value)
    case value
    when "live"
      scope.where(sitemap_autolink_entries: { enabled: true, removed_from_source: false })
    when "disabled"
      scope.where(sitemap_autolink_entries: { enabled: false })
    when "removed"
      scope.where(sitemap_autolink_entries: { removed_from_source: true })
    else
      scope
    end
  end

  # Of the keywords the current filter selects, how many compile into a
  # rule: linkable state AND a live page.
  #
  # Spelled out with `where` rather than merging the `active` scope on
  # purpose. `merge` REPLACES a conflicting condition on the same column
  # instead of anding it, so merging `removed_from_source: false` into a
  # filter for `removed_from_source: true` quietly undid the filter and
  # counted the live pages instead. Anded, the pair is a contradiction —
  # which is the true answer: nothing on a removed page links.
  def linking_count(source)
    scope = term_scope(source)
    scope = scope.where(state: validated_state(source[:state])) if source[:state].present?
    scope
      .where(state: SitemapAutolinkTerm::LINKABLE_STATES)
      .where(sitemap_autolink_entries: { enabled: true, removed_from_source: false })
      .count
  end

  # Which of THIS page's phrases another page also claims, so a keyword
  # that is fought over is marked where the admin is reading it instead
  # of only in a report they have to go looking for. One extra query,
  # bounded by the phrases on screen.
  def duplicate_phrases(entries)
    phrases = entries.flat_map { |e| e.terms.map(&:normalized_phrase) }.uniq
    return Set.new if phrases.empty?
    SitemapAutolinkTerm
      .where(normalized_phrase: phrases)
      .group(:normalized_phrase)
      .having("COUNT(DISTINCT entry_id) > 1")
      .pluck(:normalized_phrase)
      .to_set
  end

  # Everything but the state filter, so one call serves both the listing
  # and the per-state counts drawn beside it.
  def term_scope(source)
    scope = SitemapAutolinkTerm.joins(:entry)
    scope = apply_page_state(scope, source[:page_state])
    if source[:sitemap].present?
      scope = scope.where(sitemap_autolink_entries: { id: entry_ids_in_sitemap(source[:sitemap]) })
    end
    if source[:type].present?
      scope = scope.where(sitemap_autolink_entries: { content_type: source[:type] })
    end
    if source[:origin].present? && SitemapAutolinkTerm.origins.key?(source[:origin].to_s)
      scope = scope.where(origin: source[:origin].to_s)
    end
    if source[:q].present?
      q = "%#{ActiveRecord::Base.sanitize_sql_like(source[:q])}%"
      scope =
        scope.where(
          "sitemap_autolink_terms.phrase ILIKE :q " \
            "OR sitemap_autolink_terms.normalized_phrase ILIKE :q " \
            "OR sitemap_autolink_entries.title ILIKE :q " \
            "OR sitemap_autolink_entries.url ILIKE :q",
          q: q,
        )
    end
    scope
  end

  def filtered_bulk_scope
    filter = params[:filter]
    scope = term_scope(filter)
    scope = scope.where(state: validated_state(filter[:state])) if filter[:state].present?
    scope
  end

  # One grouped query, defensive about whether the adapter hands back
  # the enum's name or its stored integer.
  def state_counts(scope)
    counted = scope.group(:state).count
    SitemapAutolinkTerm.states.each_with_object({}) do |(name, value), counts|
      counts[name] = counted[name] || counted[value] || 0
    end
  end

  # An unknown enum value assigned to `state` raises ArgumentError deep
  # in ActiveRecord (a 500); reject it as a proper invalid-parameter
  # response instead.
  def validated_state(state)
    state = state.to_s
    raise Discourse::InvalidParameters.new(:state) if !SitemapAutolinkTerm.states.key?(state)
    state
  end

  def bump
    SitemapAutolink::Catalog.bump_version!
  end

  # A run's counts and success flag are written only when it completes,
  # so an open row is NOT a failure: it is either running right now or
  # was killed mid-run by a restart. A completed run that stopped at its
  # time budget is "partial", not "failed" — FAILED stays reserved for
  # actual errors. Liveness is decided by the 10-second progress
  # heartbeat, NOT by age: a run whose heartbeat went quiet is a corpse
  # and says so within ~90 seconds (the grace covers the initial
  # sitemap downloads and worst-case 30s page fetches).
  def run_result(run)
    if run.finished_at.present?
      return "failed" if !run.success
      return "partial" if run.partial
      return "ok"
    end
    heartbeat = [run.updated_at, run.started_at].compact.max
    heartbeat && heartbeat > 90.seconds.ago ? "running" : "interrupted"
  end

  def serialize_run(run)
    {
      id: run.id,
      started_at: run.started_at,
      finished_at: run.finished_at,
      success: run.success,
      partial: run.partial,
      result: run_result(run),
      triggered_by: run.triggered_by,
      urls_seen: run.urls_seen,
      urls_excluded: run.urls_excluded,
      entries_added: run.entries_added,
      entries_retitled: run.entries_retitled,
      entries_removed: run.entries_removed,
      phrases_added: run.phrases_added,
      phrases_removed: run.phrases_removed,
      error_details: run.error_details,
      sources: run.sources,
    }
  end

  def serialize_entry(entry, duplicates: nil)
    {
      id: entry.id,
      url: entry.url,
      title: entry.title,
      content_type: entry.content_type,
      priority: entry.priority,
      enabled: entry.enabled,
      auto_discovered: entry.auto_discovered,
      removed_from_source: entry.removed_from_source,
      title_source: entry.title_source,
      source: entry.source,
      # Plural on purpose: the same URL is often listed in more than one
      # sitemap, and a card that named only one would be wrong there.
      sitemaps: entry.sitemaps.map(&:url).sort,
      last_seen_at: entry.last_seen_at,
      terms:
        entry
          .terms
          .sort_by(&:normalized_phrase)
          .map { |t| serialize_term(t, duplicates: duplicates) },
    }
  end

  def serialize_term(term, entry: nil, duplicates: nil)
    result = {
      id: term.id,
      entry_id: term.entry_id,
      phrase: term.phrase,
      normalized_phrase: term.normalized_phrase,
      state: term.state,
      origin: term.origin,
      review_reason: term.review_reason,
    }
    result[:duplicate] = duplicates.include?(term.normalized_phrase) if duplicates
    if entry
      result[:entry_url] = entry.url
      result[:entry_title] = entry.title
      result[:entry_type] = entry.content_type
      # A phrase on a disabled or vanished page compiles into no rule at
      # all; the keyword list says so rather than showing it as active.
      result[:entry_active] = entry.enabled && !entry.removed_from_source
    end
    result
  end
end
