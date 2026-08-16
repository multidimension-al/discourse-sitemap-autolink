# Discourse Sitemap Autolink

Automatically link the first mention of your site's pages in forum
posts — products, wiki articles, documentation, anything with a
sitemap. Point the plugin at one or more sitemap URLs; it builds and
maintains a catalog of pages and matching phrases, and inserts normal,
reversible links while Discourse cooks each post.

- **Your post content is never modified.** Links are added only to the
  rendered HTML (`Post.cooked`); `Post.raw` stays exactly as the
  author wrote it. Disable a rule — or the whole plugin — and rebake,
  and every link it created is gone.
- **Fully server-side.** Matching runs once at cook time against a
  compiled, cached ruleset. No client-side JavaScript rewrites, no
  per-page-view cost, links present in the HTML for every reader and
  crawler.
- **Sitemap-driven.** The catalog syncs itself from your sitemaps on a
  schedule: new pages start linking, retitled pages update their
  phrases, deleted pages stop linking. No hand-maintained word lists.
- **Reviewable.** Risky generated phrases (short ones, generic words)
  go to a review queue instead of activating. An admin page shows the
  full catalog, every phrase, every sync, and a dry-run preview.

## How it works

```
sitemaps ──▶ daily sync job ──▶ catalog (entries + phrases) ──▶ compiled ruleset
                                                                     │
                    post created/edited/rebaked ──▶ cook ────────────┴──▶ links
```

1. **Sync.** A scheduled job (or the admin "Sync now" button) fetches
   your configured sitemaps — sitemap indexes are expanded
   automatically — and diffs them against the stored catalog by URL and
   `lastmod`. Only new or changed URLs get a page fetch to resolve the
   `<title>`; unchanged entries cost nothing. Vanished URLs are marked
   removed (and reactivate if they come back).
2. **Phrase generation.** Each page title produces conservative
   matching phrases: the title itself, plural/singular variants,
   "&"/"and" variants, parenthetical- and prefix-trimmed forms.
   Safety gates route questionable phrases (too short, too few words,
   made entirely of common English words) to a **pending-review
   queue** instead of activating them. A global excluded-terms list
   blocks phrases outright. Admins can add manual aliases, which
   always outrank generated phrases.
3. **Linking.** During Discourse's normal post cooking
   (`on(:post_process_cooked)`), one Aho–Corasick scan over the post
   finds every active phrase. The first mention of each destination
   becomes a link (limits configurable). Quoted material, code blocks,
   existing links, and excluded categories are skipped. Collisions
   (one phrase, several destinations) resolve deterministically by
   your configured type priority, then longest phrase wins.

Performance, measured with a 5,000+ phrase catalog
(`ruby script/benchmark_matcher.rb`): automaton build ~120 ms (cached
until the catalog changes), ~0.7 ms to scan a 2 KB post, ~1.9 ms for a
full parse+scan+rewrite.

## Requirements

- Discourse 3.4 or later.
- Your linked site needs a sitemap (`sitemap.xml` or a sitemap index).
  The forum and the linked site do not need to share a server or a
  domain.

## Installation

Standard Docker install — add the repository to your container's
plugin list in `/var/discourse/containers/app.yml`, then rebuild:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/discourse/docker_manager.git
          - git clone https://github.com/multidimension-al/discourse-sitemap-autolink.git
```

```sh
cd /var/discourse
./launcher rebuild app
```

**Source / custom installs:** clone the repository into your Discourse
checkout's `plugins/` directory, run migrations
(`bundle exec rake db:migrate RAILS_ENV=production`), and restart the
app and Sidekiq. The plugin adds three tables
(`sitemap_autolink_entries`, `sitemap_autolink_terms`,
`sitemap_autolink_sync_runs`).

The plugin is **disabled after install** (`sitemap_autolink_enabled`
is off) — it does nothing until you enable it, so installing is safe.

## Quick start

1. **Prove the mechanism first.** Add one manual mapping in
   `sitemap_autolink_manual_mappings`, e.g.
   `widget kit,https://example.com/shop/widget-kit,product`, and turn
   on `sitemap_autolink_enabled`. Make a test post containing the
   phrase and verify: the first mention links, the raw text is
   untouched, and clearing the mapping + rebaking removes the link.
2. **Fence off what should never link.** Set
   `sitemap_autolink_excluded_categories` for marketplace or for-sale
   areas where members' own listings shouldn't gain links
   (subcategories inherit the exclusion).
3. **Point at your sitemaps.** `sitemap_autolink_sources` takes one
   entry per sitemap as `https://example.com/sitemap.xml,content_type`.
   The content type is your own label (`product`, `wiki`, `docs`, …)
   used for priorities, CSS classes, and analytics. Add your site's
   `<title>` boilerplate to `sitemap_autolink_title_suffixes` (e.g.
   ` - Example Shop`) so stored titles are clean.
4. **Preview, then sync.** On the admin page (Admin → Plugins →
   Sitemap Autolink → Catalog), run **Preview (dry run)** to see
   exactly what would be ingested — URL counts, exclusions, resolved
   titles, proposed phrases — without writing anything. Then **Sync
   now**, or enable `sitemap_autolink_sync_enabled` for the daily job.
5. **Review.** Work through the pending-phrases queue and the
   collision report on the same page. Optionally restrict
   `sitemap_autolink_enabled_types` while a large content type is
   under review, and enable `sitemap_autolink_auto_rebake_on_changes`
   once you trust the flow.
6. **Catch up old posts.** New and edited posts link immediately;
   existing posts keep their current HTML until rebaked. Once the
   catalog looks right, press **Rebake matching posts** on the admin
   page to rebake everything that may contain an active phrase, in
   throttled background batches.

## The admin page

**Admin → Plugins → Sitemap Autolink → Catalog** is the single surface
for everything the plugin does:

- **Status** — active rule count, entry count, phrases awaiting
  review, and configuration warnings (e.g. entries whose type isn't
  currently allowed to link).
- **Preview (dry run)** — what the next sync would do, without writing.
- **Sync now / Cancel run** — trigger a sync; a running sync can be
  cancelled and keeps the work completed so far.
- **Rebake matching posts** — one click to catch existing posts up
  after an import: rebakes every post that may contain any active
  phrase, as one self-continuing background job in throttled batches
  (`sitemap_autolink_max_rebakes_per_job_run` per minute). Post
  content is never modified — only the rendered HTML refreshes.
- **Synchronization history** — every run with its trigger, URL
  counts, added/retitled/removed counts, result (OK, Partial,
  Running, Interrupted, Failed), timing/telemetry notes, and errors.
- **Catalog entries** — searchable, filterable list of every ingested
  page with its phrases; enable/disable entries and individual
  phrases inline, add aliases per entry.
- **Pending review** — approve or disable each gated phrase, singly or
  in bulk.
- **Collisions** — every phrase that points at more than one
  destination, and which one wins.

A JSON management API (staff-only) backs all of it under
`/admin/plugins/discourse-sitemap-autolink/` — `status`, `entries`,
`terms`, `pending`, `collisions`, `runs`, `sync`, `rebake` — if you
prefer to script against it.

Console tooling mirrors the page: `rake sitemap_autolink:report`,
`rake sitemap_autolink:preview[20]`, `rake sitemap_autolink:sync`.

## Settings

### Linking

| Setting | Default | Purpose |
| --- | --- | --- |
| `sitemap_autolink_enabled` | off | Master switch. |
| `sitemap_autolink_max_links_per_destination_per_post` | 1 | Times each destination may be linked per post (first mentions win). 0 = unlimited. |
| `sitemap_autolink_max_links_per_post` | 0 | Total automatic links per post. 0 = unlimited. |
| `sitemap_autolink_skip_quotes` | on | Never link inside quoted material. |
| `sitemap_autolink_include_private_messages` | off | Also link in personal messages. |
| `sitemap_autolink_excluded_categories` | – | Never link in these categories (subcategories included). |
| `sitemap_autolink_enabled_types` | – (all) | Restrict which content types may link. |
| `sitemap_autolink_type_priority` | `manual` | Collision priority order, strongest first; unlisted types rank last. |

### Catalog & phrases

| Setting | Default | Purpose |
| --- | --- | --- |
| `sitemap_autolink_sources` | – | Sitemaps to ingest, one per entry: `https://example.com/sitemap.xml,content_type`. Indexes expand automatically. |
| `sitemap_autolink_manual_mappings` | – | Manual `phrase,url,type` rules. Relative URLs resolve against the forum. |
| `sitemap_autolink_min_phrase_length` | 5 | Shorter generated phrases go to review. |
| `sitemap_autolink_min_phrase_words` | 2 | Generated phrases with fewer words go to review (letter+digit model-number tokens exempt). |
| `sitemap_autolink_generate_plurals` | on | Also generate simple plural variants. |
| `sitemap_autolink_title_suffixes` | – | Boilerplate stripped from the end of fetched titles. An entry can't contain the `\|` list separator — enter such suffixes as fragments; dangling connector punctuation is trimmed so fragments compose. |
| `sitemap_autolink_excluded_url_patterns` | – | Never ingest matching sitemap URLs (substring or `*` wildcard, e.g. `*/checkout*`). |
| `sitemap_autolink_excluded_terms` | – | Exact phrases that must never be auto-generated. Manual aliases override. |

### Synchronization

| Setting | Default | Purpose |
| --- | --- | --- |
| `sitemap_autolink_sync_enabled` | off | Run the daily sitemap→catalog job. |
| `sitemap_autolink_page_fetch_delay_ms` | 500 | Politeness pause between title fetches (new/changed URLs only). |
| `sitemap_autolink_sync_time_budget_minutes` | 30 | Max minutes per run; the run stops cleanly as **Partial** and the next run resumes the remaining work. |
| `sitemap_autolink_fetch_host_rewrites` | – | Fetch a public host via an internal target (see below). |

### Rebaking

| Setting | Default | Purpose |
| --- | --- | --- |
| `sitemap_autolink_auto_rebake_on_changes` | off | After a sync, rebake posts likely affected by phrase changes — one batched background job per sync. |
| `sitemap_autolink_auto_rebake_max_phrases` | 50 | If one sync changes more phrases than this, skip the auto-rebake entirely (so an initial import never triggers a near-full-forum rebake). |
| `sitemap_autolink_auto_rebake_max_posts` | 500 | Most posts one sync's rebake wave may touch. |
| `sitemap_autolink_max_rebakes_per_job_run` | 200 | Batch size per job run; larger waves continue in follow-up jobs a minute apart. |

### Analytics

| Setting | Default | Purpose |
| --- | --- | --- |
| `sitemap_autolink_analytics_enabled` | on | Send `internal_auto_link_click` events to Google Analytics via `gtag` or `dataLayer` when generated links are clicked. No-op if neither exists. |

## Sync behavior in detail

The sync is built to be a polite, bounded, observable crawler:

- **Only new and changed URLs are fetched.** Diffing is by URL +
  `lastmod`. Title fetches stream the response and stop as soon as
  `</title>` arrives (hard cap 512 KB), so a fetch reads a few KB of
  most pages.
- **Politeness delay** between page fetches
  (`sitemap_autolink_page_fetch_delay_ms`), and a hard **30-second cap
  per fetch** (shared across redirects, max 3), with no hidden HTTP
  retries. The fetcher identifies itself with the User-Agent
  `discourse-sitemap-autolink (+https://github.com/multidimension-al/discourse-sitemap-autolink)`
  (overridable in code if a WAF requires it).
- **Time budget.** A run that hits
  `sitemap_autolink_sync_time_budget_minutes` stops cleanly, records
  itself as **Partial** with a note, and the next run picks up the
  remaining work. Entries are never marked removed by a partial or
  errored run — removal decisions require a complete, clean pass.
- **Failed titles degrade gracefully.** If a page fetch fails, the
  entry gets a title derived from its URL slug (labeled in the admin
  UI) and still links. Retries back off exponentially — 1, 2, 4, then
  7 days — instead of taxing every run, and the entry heals to the
  real title on the first successful refetch.
- **One sync at a time.** A cross-process lock prevents overlapping
  runs; the admin "Sync now" button reports a conflict instead of
  stacking. Cancelling is sticky for 10 minutes so queued duplicates
  don't resurrect the run, and completed work is kept.
- **Honest history.** Runs heartbeat their progress; a run whose
  process died (deploy, restart) is labeled **Interrupted**, never
  left as a phantom "Running". Each run records fetch telemetry —
  pages fetched, total fetch time, slowest URLs with connect/first-byte
  phases — so slowness is diagnosable from the admin page.

## Fetching through an internal host

If the forum and the linked site share infrastructure, sustained
crawling from the forum's IP can trip the public edge (CDN or rate
limiting) even at polite speeds. `sitemap_autolink_fetch_host_rewrites`
routes fetches around it:

```
www.example.com=http://example.internal:3000
```

Connections go to the internal target with a `Host: www.example.com`
header; redirects re-apply the mapping. Every URL **stored and linked
stays the public one** — the rewrite affects only how the sync fetches.
The target accepts `host`, `host:port`, or `scheme://host:port`.

## Title cleanup

Fetched `<title>` text is normalized before phrase generation:
configured suffixes are stripped repeatedly (so stacked boilerplate
like ` - Example Wiki | Example.com` comes off even when entered as
fragments), dangling connector punctuation is trimmed, and stray
backslash-escaped quotes are unescaped. Cleanup is also re-applied to
already-stored titles on every sync — tightening your suffix list
retroactively fixes the catalog and regenerates the affected phrases,
no refetching involved.

## What links look like

```html
<a href="https://example.com/shop/widget-kit"
   class="sitemap-autolink sitemap-autolink-product"
   data-sitemap-autolink="true"
   data-autolink-type="product"
   data-autolink-term="widget kit"
   data-autolink-id="123">widget kit</a>
```

Canonical URLs, no tracking parameters. Style them per content type
via the `sitemap-autolink-<type>` class in your theme.

## FAQ

**Does it ever change what members wrote?** No. Links exist only in
the rendered HTML. Rebaking a post with the plugin disabled produces
exactly what Discourse would have produced without it.

**What happens when a page disappears from the sitemap?** Its entry is
marked removed and stops linking in anything cooked from then on;
existing cooked posts keep the link until they're next rebaked or
edited (the auto-rebake wave handles recent ones if enabled). If the
URL returns to the sitemap, the entry — and its phrases — reactivate,
and freed phrases are available to other pages.

**Does every sync refetch every page?** No. Unchanged URLs are never
fetched. A page is fetched when it's new, its `lastmod` changed, or a
previously failed title is due for its backed-off retry.

**Why isn't a phrase linking?** Check, in order: is it in the
pending-review queue (approve it); is its content type allowed by
`sitemap_autolink_enabled_types`; is the post in an excluded category;
was the phrase already used up by the per-post limits; does a
higher-priority entry own the phrase (collision report). The admin
status box calls out the common misconfigurations.

**How do I undo everything?** Turn off `sitemap_autolink_enabled` and
rebake (`rake posts:rebake`, or let posts rebake naturally). Removing
the plugin afterwards leaves its three tables behind; drop them
manually if you want a spotless database.

## Development

```sh
# in a Discourse checkout with the plugin cloned into plugins/
LOAD_PLUGINS=1 bin/rspec plugins/discourse-sitemap-autolink/spec

# dependency-free checks (plain Ruby + nokogiri, no Discourse needed):
ruby script/local_check.rb          # matcher + HTML applier behavior
ruby script/benchmark_matcher.rb    # performance with a large catalog

# dry-run a real sitemap without installing anything:
ruby script/preview_sync.rb --source "https://example.com/sitemap.xml,content" --limit 10
```

`spec/integration/sitemap_autolink_cooking_spec.rb` is the behavioral
contract: creation, editing, rebake applies/removes/retargets links,
per-post limits, quote/code/existing-link safety, category exclusions,
pending-review gating, and type restrictions.

## License

MIT — see [LICENSE](LICENSE).

This repository's history began as a fork of
[discourse-linkify-words](https://github.com/discourse/discourse-linkify-words)
(MIT, © 2014 New Relic, Inc. and community maintainers). The plugin
was subsequently rewritten from scratch into the sitemap-driven system
documented here; the license and original copyright notice are
retained.
