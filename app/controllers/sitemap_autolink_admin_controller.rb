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
#   GET    /admin/plugins/discourse-sitemap-autolink/collisions?q=&page=
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
  # from every keyword. The cap bounds the response of a pathological
  # catalog rather than the work, which is linear in total keyword
  # length.
  MAX_OVERLAP_PAIRS = 5000

  def status
    last_run = SitemapAutolinkSyncRun.recent.first
    render json: {
             enabled: SiteSetting.sitemap_autolink_enabled,
             sync_enabled: SiteSetting.sitemap_autolink_sync_enabled,
             sources_configured: SiteSetting.sitemap_autolink_sources.present?,
             catalog_version: SitemapAutolink::Catalog.version,
             active_rules: SitemapAutolink::Catalog.ruleset.size,
             entries: SitemapAutolinkEntry.count,
             active_entries: SitemapAutolinkEntry.active.count,
             terms: SitemapAutolinkTerm.count,
             pending_terms: SitemapAutolinkTerm.pending_review.count,
             entry_types: entry_types,
             enabled_types_setting: SiteSetting.sitemap_autolink_enabled_types,
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
    scope = SitemapAutolinkEntry.includes(:terms).order(:url)
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
             # Phrase counts, not page counts: the state filters and the
             # bulk actions beside them both act on phrases, and they
             # must agree about how many.
             state_counts: state_counts(term_scope(params)),
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

  # Every phrase claimed by more than one page.
  #
  # Detection deliberately does NOT pre-filter to active entries and
  # linkable terms. Scoping it that way made the report disagree with
  # the catalog an admin is looking at: four pages visibly claiming
  # one phrase were reported as zero conflicts because the query
  # silently dropped whichever of them were disabled or awaiting
  # review. Detect broadly, then annotate — `linking` marks the
  # candidates actually competing, `winner` the one the compiled
  # ruleset chose, and `linking_candidates` how many are in the fight.
  # `only_competing=true` narrows to phrases where that is more than
  # one, for an admin who wants just the live contests.
  def collisions
    ruleset = SitemapAutolink::Catalog.ruleset
    winners = ruleset.rules.index_by { |r| r[:phrase] }
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
    # need `linking`, which is two columns of the entry plus the term's
    # own state.
    candidates_by_phrase =
      SitemapAutolinkTerm
        .joins(:entry)
        .where(normalized_phrase: duplicated)
        .pluck(
          "sitemap_autolink_terms.normalized_phrase",
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
        winner = winners.dig(phrase, :url)
        candidates =
          (candidates_by_phrase[phrase] || []).map do |_p, url, title, type, state, enabled, removed|
            name = SitemapAutolinkTerm.state_name(state)
            linking =
              SitemapAutolinkTerm::LINKABLE_STATES.include?(name) && enabled && !removed
            {
              url: url,
              title: title,
              type: type,
              state: name,
              linking: linking,
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
    reports.select! { |r| r[:linking_candidates] > 1 } if params[:only_competing] == "true"

    page = current_page
    render json: {
             total: reports.size,
             page: page,
             per_page: PAGE_SIZE,
             pages: page_count(reports.size),
             competing: reports.count { |r| r[:linking_candidates] > 1 },
             collisions: reports[page * PAGE_SIZE, PAGE_SIZE] || [],
           }
  end

  # Keywords that sit inside a longer keyword.
  #
  # "Acme Widget Kit Gasket Set" contains "Widget Kit" and "Gasket
  # Set". All three are keywords; wherever the long one
  # appears it takes the whole span and the two short ones do not fire,
  # which is what an admin needs told.
  #
  # Detection runs over the WHOLE catalog, not the compiled ruleset. The
  # ruleset holds only linkable terms on live pages, deduplicated to one
  # rule per phrase — so sourcing the report from it hid exactly the
  # overlaps worth seeing: a keyword still awaiting review, or one on a
  # page someone disabled, silently had no overlaps at all.
  def overlaps
    owners = Hash.new { |all, phrase| all[phrase] = [] }
    SitemapAutolinkTerm
      .joins(:entry)
      .pluck(
        "sitemap_autolink_terms.normalized_phrase",
        "sitemap_autolink_entries.url",
        "sitemap_autolink_entries.title",
        "sitemap_autolink_entries.content_type",
        "sitemap_autolink_terms.state",
        "sitemap_autolink_entries.enabled",
        "sitemap_autolink_entries.removed_from_source",
      )
      .each do |phrase, url, title, type, state, enabled, removed|
        name = SitemapAutolinkTerm.state_name(state)
        owners[phrase] << {
          url: url,
          title: title,
          type: type,
          state: name,
          linking: SitemapAutolinkTerm::LINKABLE_STATES.include?(name) && enabled && !removed,
        }
      end

    # One automaton over every distinct keyword, then each keyword is
    # scanned through it: whatever else it contains — on word
    # boundaries, so "kit" is not found inside "kitbash" — is a keyword
    # it swallows. Linear in total keyword length; ~100 ms at 7,500.
    matcher = SitemapAutolink::Matcher.new(owners.keys.map { |phrase| { phrase: phrase } })
    covered_by = Hash.new { |shadowed, phrase| shadowed[phrase] = [] }
    truncated = false
    pairs = 0
    owners.each_key do |long|
      matcher
        .scan(long)
        .each do |candidate|
          inner = candidate[:rule][:phrase]
          next if inner == long
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
    if params[:only_competing] == "true"
      phrases.select! { |phrase| linking.call(phrase) && covered_by[phrase].any?(&linking) }
    end
    phrases.sort!

    page = current_page
    render json: {
             total: phrases.size,
             page: page,
             per_page: PAGE_SIZE,
             pages: page_count(phrases.size),
             truncated: truncated,
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

  private

  def current_page
    params[:page].to_i.clamp(0, 10_000)
  end

  def page_count(total)
    (total.to_f / PAGE_SIZE).ceil
  end

  def entry_types
    SitemapAutolinkEntry.distinct.order(:content_type).pluck(:content_type)
  end

  def linkable_terms
    SitemapAutolinkTerm.linkable.joins(:entry).merge(SitemapAutolinkEntry.active)
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
