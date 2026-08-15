# frozen_string_literal: true

# JSON management API for the autolink catalog. Staff only (routes are
# mounted under the admin namespace with StaffConstraint).
#
#   GET    /admin/plugins/sitemap-autolink/status
#   GET    /admin/plugins/sitemap-autolink/entries?q=&type=&state=&page=
#   POST   /admin/plugins/sitemap-autolink/entries        (manual entry)
#   PUT    /admin/plugins/sitemap-autolink/entries/:id    (enable/priority/url…)
#   POST   /admin/plugins/sitemap-autolink/terms          (add alias)
#   PUT    /admin/plugins/sitemap-autolink/terms/:id      (approve/disable…)
#   DELETE /admin/plugins/sitemap-autolink/terms/:id
#   GET    /admin/plugins/sitemap-autolink/collisions
#   GET    /admin/plugins/sitemap-autolink/pending
#   POST   /admin/plugins/sitemap-autolink/sync
#   POST   /admin/plugins/sitemap-autolink/rebuild
#   POST   /admin/plugins/sitemap-autolink/rebake         (phrase= or all=true)
class GbfansAutolinkAdminController < Admin::AdminController
  requires_plugin GbfansAutolink::PLUGIN_NAME

  PAGE_SIZE = 50

  def status
    render json: {
             catalog_version: GbfansAutolink::Catalog.version,
             active_rules: GbfansAutolink::Catalog.ruleset.size,
             entries: GbfansAutolinkEntry.count,
             active_entries: GbfansAutolinkEntry.active.count,
             terms: GbfansAutolinkTerm.count,
             pending_terms: GbfansAutolinkTerm.pending_review.count,
           }
  end

  def entries
    scope = GbfansAutolinkEntry.includes(:terms).order(:url)
    scope = scope.where(content_type: params[:type]) if params[:type].present?
    scope = scope.where(enabled: params[:enabled] == "true") if params[:enabled].present?
    if params[:q].present?
      q = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q])}%"
      scope =
        scope.where(
          "gbfans_autolink_entries.url ILIKE :q OR gbfans_autolink_entries.title ILIKE :q",
          q: q,
        )
    end
    page = params[:page].to_i.clamp(0, 10_000)
    render json: {
             total: scope.count,
             page: page,
             entries:
               scope.offset(page * PAGE_SIZE).limit(PAGE_SIZE).map { |e| serialize_entry(e) },
           }
  end

  def create_entry
    entry =
      GbfansAutolinkEntry.create!(
        url: GbfansAutolinkEntry.normalize_url(params.require(:url)),
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
    entry = GbfansAutolinkEntry.find(params[:id])
    changes = {}
    changes[:enabled] = params[:enabled] == "true" if params.key?(:enabled)
    changes[:priority] = params[:priority].presence&.to_i if params.key?(:priority)
    if params[:url].present?
      changes[:url] = GbfansAutolinkEntry.normalize_url(params[:url])
    end
    changes[:title] = params[:title] if params[:title].present?
    entry.update!(changes)
    bump
    render json: serialize_entry(entry.reload)
  end

  def create_term
    entry = GbfansAutolinkEntry.find(params.require(:entry_id))
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
    term = GbfansAutolinkTerm.find(params[:id])
    term.update!(state: params.require(:state))
    bump
    render json: serialize_term(term)
  end

  def destroy_term
    GbfansAutolinkTerm.find(params[:id]).destroy!
    bump
    render json: success_json
  end

  # Aliases claimed by more than one active entry, with the winner the
  # compiled ruleset actually chose.
  def collisions
    ruleset = GbfansAutolink::Catalog.ruleset
    winners = ruleset.rules.index_by { |r| r[:phrase] }
    duplicated =
      GbfansAutolinkTerm
        .linkable
        .joins(:entry)
        .merge(GbfansAutolinkEntry.active)
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
                     GbfansAutolinkTerm
                       .linkable
                       .joins(:entry)
                       .where(normalized_phrase: phrase)
                       .pluck(
                         "gbfans_autolink_entries.url",
                         "gbfans_autolink_entries.content_type",
                       )
                       .map { |url, type| { url: url, type: type } },
                 }
               end,
           }
  end

  def pending
    terms =
      GbfansAutolinkTerm
        .pending_review
        .includes(:entry)
        .order(:normalized_phrase)
        .limit(500)
    render json: { pending: terms.map { |t| serialize_term(t) } }
  end

  def sync
    Jobs.enqueue(:gbfans_autolink_daily_sync)
    render json: success_json
  end

  def rebuild
    bump
    render json: success_json.merge(catalog_version: GbfansAutolink::Catalog.version)
  end

  def rebake
    if params[:all] == "true"
      # Full-forum rebakes go through Discourse's own tooling
      # (rake posts:rebake) — deliberately not one click here.
      render json: failed_json.merge(error: "use `rake posts:rebake` for a full rebake"),
             status: 422
    elsif params[:phrase].present?
      Jobs.enqueue(:gbfans_autolink_selective_rebake, phrase: params[:phrase])
      render json: success_json
    else
      render json: failed_json, status: 422
    end
  end

  private

  def bump
    GbfansAutolink::Catalog.bump_version!
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

  def serialize_term(term)
    {
      id: term.id,
      entry_id: term.entry_id,
      phrase: term.phrase,
      normalized_phrase: term.normalized_phrase,
      state: term.state,
      origin: term.origin,
      review_reason: term.review_reason,
    }
  end
end
