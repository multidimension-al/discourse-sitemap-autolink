# discourse-sitemap-autolink

A Discourse plugin that automatically links the first mention of your
site's pages in forum posts. Point it at any site's sitemaps — a shop,
a wiki, documentation, anything with canonical URLs — and posts gain
normal, reversible internal links during Discourse's standard post
cooking. `Post.raw` is never modified; links live only in
`Post.cooked`, so changing or removing a rule and rebaking updates or
removes them cleanly.

## How it works

- **Linking** happens in `on(:post_process_cooked)`: CookedPostProcessor
  re-cooks from raw, hands the plugin a Loofah doc, the plugin inserts
  links, and `Jobs::ProcessPost` persists the result. Create, edit,
  `rebake!` and bulk rebakes all funnel through this hook, so disabling
  a rule + rebaking removes its links, structurally.
- **Matching** is one Aho–Corasick scan per post over a compiled,
  cached ruleset (rebuilt only when the catalog changes) — never
  per-phrase regex loops. Benchmarked with a 5,000+ phrase catalog:
  automaton build ~120 ms (cached), ~0.7 ms per 2 KB post, full
  parse+scan+rewrite ~1.9 ms (`ruby script/benchmark_matcher.rb`).
- **Ingestion** is a daily scheduled job that fetches the configured
  sitemaps (sitemap **indexes are expanded automatically**), diffs
  against the stored catalog by URL + `lastmod`, fetches pages for
  titles **only** for new/changed URLs — spaced by
  `sitemap_autolink_page_fetch_delay_ms` so a first import doesn't
  read as a scraping burst to the source site's firewall —
  regenerates matching phrases,
  and optionally enqueues **one** bounded, batched rebake job for the
  posts the changes likely affect (never one job per phrase, and never
  at all when the change set is catalog-scale — see
  `sitemap_autolink_auto_rebake_max_phrases`). Post cooking never
  fetches anything from the network.
- **Safety / review**: generated phrases pass gates — minimum length,
  minimum word count (model numbers like "Mark-2" exempt), a
  common-English-word check, and a global excluded-terms list. Anything
  questionable lands in a `pending_review` queue instead of linking;
  admins approve, disable, or add aliases. Manual terms always outrank
  generated ones, and explicit manual aliases bypass the excluded list.
- **Priorities**: phrase collisions resolve deterministically by the
  configurable `sitemap_autolink_type_priority` order; at match time,
  leftmost match wins, then the longest phrase ("Deluxe Widget Kit"
  beats "Widget Kit"), with per-destination and total per-post limits.
- **Markup**: `<a class="sitemap-autolink sitemap-autolink-<type>"
  data-sitemap-autolink="true" data-autolink-type="…"
  data-autolink-term="…" data-autolink-id="…">` — canonical URLs, no
  tracking parameters. An optional, isolated client initializer sends
  `internal_auto_link_click` GA4 events via `gtag`/`dataLayer`.

## Install

Standard Docker install — add the repo to the plugin list in
`/var/discourse/containers/app.yml`, then rebuild:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/discourse/docker_manager.git
          - git clone https://github.com/ajquick/discourse-sitemap-autolink.git
```

```sh
cd /var/discourse && ./launcher rebuild app
```

If the repository is private, the container must be able to clone it:
make it public, or use a fine-grained personal access token (Contents:
read-only) in the clone URL —
`https://<TOKEN>@github.com/ajquick/discourse-sitemap-autolink.git`.

The plugin is **disabled after install** (`sitemap_autolink_enabled`
off) — it does nothing until you enable it, so installing is safe.

## Seeing what it does

Nothing here is a black box — every stage has a visible surface:

- **Admin page** — Admin → Plugins → Sitemap Autolink → **Catalog**:
  status summary, a **“Preview (dry run)”** button showing exactly what
  the next sync would ingest (URL counts, pattern exclusions, resolved
  titles, proposed phrases with review states), a **“Sync now”**
  button, the full **synchronization history** (every run: when, what
  was fetched, added/retitled/removed counts, errors), the searchable
  **catalog** (every entry with its phrases; enable/disable inline),
  the **pending-review queue** (approve/disable each proposed phrase),
  and the **collision report**.
- **Sync audit trail** — every run is stored in
  `sitemap_autolink_sync_runs` (also `GET
  /admin/plugins/discourse-sitemap-autolink/runs`), plus a summary line in
  `/logs`.
- **Dry run without installing anything**:
  `ruby script/preview_sync.rb --source "https://example.com/sitemap.xml,content" --limit 10`
  fetches real sitemaps and prints what would be ingested and linked —
  plain Ruby, no Discourse, nothing written.
- **Console tooling** — `rake sitemap_autolink:report` (status, runs,
  sample entries, pending queue), `rake sitemap_autolink:preview[20]`,
  `rake sitemap_autolink:sync`.

## Getting started

1. Set `sitemap_autolink_manual_mappings` with a couple of test rules,
   e.g. `widget kit,https://example.com/shop/widget-kit,product`, and
   enable `sitemap_autolink_enabled`. Make a test post and verify: the
   first mention links, raw is unchanged, editing works, and clearing
   the mapping + rebaking removes the link.
2. Set `sitemap_autolink_excluded_categories` for any marketplace /
   for-sale areas where members' own listings should not gain links
   (subcategories inherit the exclusion).
3. Configure `sitemap_autolink_sources`, one per entry as
   `https://example.com/sitemap.xml,content_type` — the type is your
   label (product, wiki, docs, …) for priorities, styling and
   analytics. Add `sitemap_autolink_title_suffixes` for your site's
   `<title>` boilerplate (e.g. ` - Example Shop`).
4. Enable `sitemap_autolink_sync_enabled` (or POST
   `/admin/plugins/discourse-sitemap-autolink/sync` to run one immediately),
   then review the `pending` queue and `collisions` report.
5. Optionally restrict `sitemap_autolink_enabled_types` while you
   review a large content type, and enable
   `sitemap_autolink_auto_rebake_on_changes` once you trust the flow.

## Settings

| Setting | Default | Purpose |
| --- | --- | --- |
| `sitemap_autolink_enabled` | off | master switch |
| `sitemap_autolink_sources` | – | `sitemap_url,content_type` entries; indexes auto-expand |
| `sitemap_autolink_manual_mappings` | – | manual `phrase,url,type` rules (relative URL = forum-internal) |
| `sitemap_autolink_max_links_per_destination_per_post` | 1 | once per destination per post |
| `sitemap_autolink_max_links_per_post` | 0 | total cap per post (0 = unlimited) |
| `sitemap_autolink_skip_quotes` | on | don't link inside quoted material |
| `sitemap_autolink_excluded_categories` | – | never link in these categories + subcategories |
| `sitemap_autolink_enabled_types` | – (all) | restrict which types may link |
| `sitemap_autolink_type_priority` | manual | collision priority order, strongest first |
| `sitemap_autolink_min_phrase_length` / `_min_phrase_words` | 5 / 2 | review gates for generated phrases |
| `sitemap_autolink_generate_plurals` | on | simple plural variants |
| `sitemap_autolink_title_suffixes` | – | strip site boilerplate from titles (re-applied to stored titles each sync) |
| `sitemap_autolink_excluded_url_patterns` | – | never ingest matching sitemap URLs (substring or `*` wildcard, e.g. `*/checkout*`) |
| `sitemap_autolink_excluded_terms` | – | never auto-generate these phrases |
| `sitemap_autolink_sync_enabled` | off | daily sitemap → catalog job |
| `sitemap_autolink_page_fetch_delay_ms` | 500 | politeness pause between title fetches |
| `sitemap_autolink_sync_time_budget_minutes` | 30 | max minutes per run; the next run resumes (per-fetch hard cap is 30s) |
| `sitemap_autolink_auto_rebake_on_changes` | off | one batched rebake job after each sync |
| `sitemap_autolink_auto_rebake_max_phrases` | 50 | skip auto-rebake when a sync changes more phrases than this (initial imports never mass-rebake) |
| `sitemap_autolink_auto_rebake_max_posts` | 500 | total posts one sync's rebake wave may touch |
| `sitemap_autolink_analytics_enabled` | on | GA4 click events (no-op without gtag/dataLayer) |

## Administration

JSON management API (staff only) under
`/admin/plugins/discourse-sitemap-autolink/…`: `status`, `entries` (search /
filter / paginate), entry create/update (enable/disable, priority, URL
override), term create/update/delete (add aliases, approve
`pending_review`, disable), `collisions`, `pending`, `sync`, `rebuild`,
`rebake` (targeted, per-phrase; full-forum deliberately stays with
`rake posts:rebake`). See
`app/controllers/sitemap_autolink_admin_controller.rb` for parameters.

## Development

```sh
# in a Discourse checkout with this plugin cloned into plugins/
LOAD_PLUGINS=1 bin/rspec plugins/discourse-sitemap-autolink/spec

# dependency-free checks (plain Ruby + nokogiri, no Discourse needed):
ruby script/local_check.rb          # matcher + HTML applier behavior
ruby script/benchmark_matcher.rb    # performance with a large catalog
```

`spec/integration/sitemap_autolink_cooking_spec.rb` is the behavioral
contract: creation, editing, rebake-applies/removes/retargets, per-post
limits, quote/code/manual-link safety, category exclusions,
catalog-driven linking, pending-review gating, and type restrictions.
