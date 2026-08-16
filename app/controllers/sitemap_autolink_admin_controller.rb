# frozen_string_literal: true

# JSON management API for the autolink catalog. Staff only (routes are
# mounted under the admin namespace with StaffConstraint).
#
#   GET    /admin/plugins/discourse-sitemap-autolink/status
#   GET    /admin/plugins/discourse-sitemap-autolink/entries?q=&type=&enabled=&page=
#   POST   /admin/plugins/discourse-sitemap-autolink/entries      (manual entry)
#   PUT    /admin/plugins/discourse-sitemap-autolink/entries/:id  (enable/priority/url…)
#   POST   /admin/plugins/discourse-sitemap-autolink/terms        (add alias)
#   PUT    /admin/plugins/discourse-sitemap-autolink/terms/:id    (approve/disable…)
#   DELETE /admin/plugins/discourse-sitemap-autolink/terms/:id
#   GET    /admin/plugins/discourse-sitemap-autolink/collisions
#   GET    /admin/plugins/discourse-sitemap-autolink/pending
#   POST   /admin/plugins/discourse-sitemap-autolink/sync
#   POST   /admin/plugins/discourse-sitemap-autolink/rebuild
#   POST   /admin/plugins/discourse-sitemap-autolink/rebake       (phrase= or all=true)
class SitemapAutolinkAdminController < Admin::AdminController
  requires_plugin SitemapAutolink::PLUGIN_NAME

  PAGE_SIZE = 50

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
             entry_types: SitemapAutolinkEntry.distinct.order(:content_type).pluck(:content_type),
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
             status: 422
      return
    end
    limit = (params[:limit] || 10).to_i.clamp(1, 50)
    render json: SitemapAutolink::SitemapSync.new.preview(limit_per_source: limit)
  end

  def entries
    scope = SitemapAutolinkEntry.includes(:terms).order(:url)
    scope = scope.where(content_type: params[:type]) if params[:type].present?
    scope = scope.where(enabled: params[:enabled] == "true") if params[:enabled].present?
    if params[:q].present?
      q = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q])}%"
      scope =
        scope.where(
          "sitemap_autolink_entries.url ILIKE :q OR sitemap_autolink_entries.title ILIKE :q",
          q: q,
        )
    end
    if params[:pending] == "true"
      scope =
        scope.where(
          id: SitemapAutolinkTerm.pending_review.select(:entry_id),
        )
    end
    page = params[:page].to_i.clamp(0, 10_000)
    total = scope.count
    render json: {
             total: total,
             page: page,
             per_page: PAGE_SIZE,
             pages: (total.to_f / PAGE_SIZE).ceil,
             types: SitemapAutolinkEntry.distinct.order(:content_type).pluck(:content_type),
             entries:
               scope.offset(page * PAGE_SIZE).limit(PAGE_SIZE).map { |e| serialize_entry(e) },
           }
  end

  # Bulk state change for terms, e.g. clearing a large review queue.
  def bulk_terms
    ids = Array(params[:ids]).map(&:to_i).first(500)
    state = params.require(:state)
    raise Discourse::InvalidParameters.new(:state) if !SitemapAutolinkTerm.states.key?(state)
    updated = SitemapAutolinkTerm.where(id: ids).update_all(state: SitemapAutolinkTerm.states[state], updated_at: Time.zone.now)
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
    changes[:enabled] = params[:enabled] == "true" if params.key?(:enabled)
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
        state: params[:state].presence || :approved,
      )
    bump
    render json: serialize_term(term)
  end

  def update_term
    term = SitemapAutolinkTerm.find(params[:id])
    term.update!(state: params.require(:state))
    bump
    render json: serialize_term(term)
  end

  def destroy_term
    SitemapAutolinkTerm.find(params[:id]).destroy!
    bump
    render json: success_json
  end

  # Aliases claimed by more than one active entry, with the winner the
  # compiled ruleset actually chose.
  def collisions
    ruleset = SitemapAutolink::Catalog.ruleset
    winners = ruleset.rules.index_by { |r| r[:phrase] }
    duplicated =
      SitemapAutolinkTerm
        .linkable
        .joins(:entry)
        .merge(SitemapAutolinkEntry.active)
        .group(:normalized_phrase)
        .having("COUNT(DISTINCT entry_id) > 1")
        .pluck(:normalized_phrase)
    render json: {
             collisions:
               duplicated.sort.map do |phrase|
                 {
                   phrase: phrase,
                   winner: winners.dig(phrase, :url),
                   candidates:
                     SitemapAutolinkTerm
                       .linkable
                       .joins(:entry)
                       .where(normalized_phrase: phrase)
                       .pluck(
                         "sitemap_autolink_entries.url",
                         "sitemap_autolink_entries.content_type",
                       )
                       .map { |url, type| { url: url, type: type } },
                 }
               end,
           }
  end

  def pending
    terms =
      SitemapAutolinkTerm
        .pending_review
        .includes(:entry)
        .order(:normalized_phrase)
        .limit(500)
    render json: {
             total: SitemapAutolinkTerm.pending_review.count,
             pending: terms.map { |t| serialize_term(t, entry: t.entry) },
           }
  end

  def sync
    if Discourse.redis.get(SitemapAutolink::SitemapSync::RUNNING_LOCK_KEY).present?
      return(
        render json:
                 failed_json.merge(
                   error: "A synchronization is already running — cancel it or wait for it to finish.",
                 ),
               status: 409
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
      # Full-forum rebakes go through Discourse's own tooling
      # (rake posts:rebake) — deliberately not one click here.
      render json: failed_json.merge(error: "use `rake posts:rebake` for a full rebake"),
             status: 422
    elsif params[:phrase].present?
      Jobs.enqueue(:sitemap_autolink_rebake_posts, phrases: [params[:phrase]])
      render json: success_json
    else
      render json: failed_json, status: 422
    end
  end

  private

  def bump
    SitemapAutolink::Catalog.bump_version!
  end

  # A run's counts and success flag are written only when it completes,
  # so an open row is NOT a failure: it is either running right now or
  # was killed mid-run by a restart. Say which, instead of rendering
  # "FAILED 0 0 0 0" for a sync that is happily working. A completed
  # run that stopped at its time budget is "partial", not "failed" —
  # FAILED stays reserved for actual errors.
  def run_result(run)
    if run.finished_at.present?
      return "failed" if !run.success
      return "partial" if run.partial
      return "ok"
    end
    run.started_at && run.started_at > 2.hours.ago ? "running" : "interrupted"
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

  def serialize_entry(entry)
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
      terms: entry.terms.sort_by(&:normalized_phrase).map { |t| serialize_term(t) },
    }
  end

  def serialize_term(term, entry: nil)
    result = {
      id: term.id,
      entry_id: term.entry_id,
      phrase: term.phrase,
      normalized_phrase: term.normalized_phrase,
      state: term.state,
      origin: term.origin,
      review_reason: term.review_reason,
    }
    if entry
      result[:entry_url] = entry.url
      result[:entry_title] = entry.title
      result[:entry_type] = entry.content_type
    end
    result
  end
end
