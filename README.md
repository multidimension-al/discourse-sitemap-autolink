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
   finds every active phrase. The **most specific** mention of each
   destination becomes a link (limits configurable): where phrases
   overlap the longest one wins, and a page's per-post link budget is
   spent on its fullest mention rather than on whichever stray word
   for it happened to appear first. Equal-length matches fall back to
   document order, so repeated mentions of one phrase link the first.
   Quoted material, code blocks, existing links, and excluded
   categories are skipped. Collisions (one phrase, several
   destinations) resolve deterministically by your configured type
   priority.

Performance, measured with a 5,000+ phrase catalog
(`ruby script/benchmark_matcher.rb`): automaton build ~120 ms (cached
until the catalog changes), ~0.7 ms to scan a 2 KB post, ~1.9 ms for a
full parse+scan+rewrite.

## A worked example

Say your community runs a technical wiki at `www.example.com`, and its
sitemap lists five articles:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://www.example.com/wiki/soldering-iron-maintenance</loc><lastmod>2026-07-02</lastmod></url>
  <url><loc>https://www.example.com/wiki/mosfet-driver-board</loc><lastmod>2026-07-05</lastmod></url>
  <url><loc>https://www.example.com/wiki/li-ion-battery-pack</loc><lastmod>2026-07-11</lastmod></url>
  <url><loc>https://www.example.com/wiki/pcb-etching</loc><lastmod>2026-07-19</lastmod></url>
  <url><loc>https://www.example.com/wiki/flux</loc><lastmod>2026-07-23</lastmod></url>
</urlset>
```

You configure two settings:

| Setting | Value |
| --- | --- |
| `sitemap_autolink_sources` | `https://www.example.com/wiki-sitemap.xml,wiki` |
| `sitemap_autolink_title_suffixes` | two entries: `- Example Wiki` and `Example.com` |

**Step 1 — the sync reads the sitemap and fetches each page's
`<title>`.** Like most sites, the wiki decorates every title with
boilerplate, which the suffix list strips:

| Fetched `<title>` | Stored title |
| --- | --- |
| Soldering Iron Maintenance - Example Wiki \| Example.com | Soldering Iron Maintenance |
| MOSFET Driver Board - Example Wiki \| Example.com | MOSFET Driver Board |
| Li-Ion Battery Pack - Example Wiki \| Example.com | Li-Ion Battery Pack |
| PCB Etching - Example Wiki \| Example.com | PCB Etching |
| Flux - Example Wiki \| Example.com | Flux |

(Why two suffix *fragments*? The full boilerplate contains `|`, which
is Discourse's list-setting separator, so it can't be one entry.
Enter the pieces — after each strip the plugin trims the connector
punctuation left dangling, so the fragments compose back into the
whole suffix.)

**Step 2 — each clean title becomes matching phrases, with safety
gates.**

| Stored title | Generated phrases | State |
| --- | --- | --- |
| Soldering Iron Maintenance | soldering iron maintenance(s) | active |
| MOSFET Driver Board | mosfet driver board(s) | active |
| Li-Ion Battery Pack | li-ion battery pack(s) | active |
| PCB Etching | pcb etching(s) | active |
| Flux | flux, fluxes | **pending review** — short, single word |

"Flux" is exactly the kind of phrase that would wreck a forum if it
auto-linked — it appears in every third post about soldering. The
gates hold it in the review queue for a human: approve it, disable
it, or give the entry a more specific manual alias (say, "flux pen")
instead.

**Step 3 — posts link themselves at cook time.** A member writes
(and this raw text is never modified):

> Rebuilt the driver stage last night using the mosfet driver board
> design from the wiki, then cleaned the tips per soldering iron
> maintenance. Flux everywhere, but the etching came out fine.

The rendered post links the first mention of each active phrase:

> Rebuilt the driver stage last night using the **[mosfet driver
> board]** design from the wiki, then cleaned the tips per
> **[soldering iron maintenance]**. Flux everywhere, but the etching
> came out fine.

as real anchors in the cooked HTML:

```html
… using the <a href="https://www.example.com/wiki/mosfet-driver-board"
  class="sitemap-autolink sitemap-autolink-wiki"
  data-sitemap-autolink="true" data-autolink-type="wiki"
  data-autolink-term="mosfet driver board">mosfet driver board</a> design …
```

Notice what did **not** happen: matching is case-insensitive (the
member typed "mosfet", the title says "MOSFET"); "Flux" stayed plain
(still pending review); "etching" stayed plain (the phrase is "pcb
etching" — fragments of phrases never match); and if the post
mentioned the driver board five times, only the first mention links.

## Why not just a hand-made word list?

For five pages, a watched-words rule or a linkify-style word list does
the same job. The difference is everything after day one:

- **The wiki has 3,000 articles, not five** — and someone adds more
  every week. Nobody types 3,000 phrase→URL pairs into a settings
  field, and nobody maintains them afterwards. Here the sitemap *is*
  the word list: a new article starts linking after the next sync, on
  its own.
- **Pages change.** Rename "PCB Etching" to "PCB Etching Guide" and
  the phrases follow the new title automatically. Delete the article
  and its link rules retire (existing posts clean up on their next
  rebake); restore it and everything comes back. A manual list rots
  silently.
- **Scale needs judgment, not just automation.** Mechanically
  generating phrases from thousands of titles produces some clunkers —
  so the gates route short and generic candidates to a review queue
  where approving or disabling is one click, and a collision report
  shows when two pages claim the same phrase. You review the
  exceptions instead of entering the data.
- **The links are real.** They're inserted server-side into the cooked
  HTML — visible to search engines, present in email notifications and
  RSS, no JavaScript rewriting on every page view. And because raw is
  never touched, disabling a rule (or the whole plugin) and rebaking
  removes every trace.


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

**Admin → Plugins → Sitemap Autolink → Catalog** is the surface for
everything the plugin does. A few thousand sitemap URLs produce tens of
thousands of phrases, so each concern gets its own tab — and each tab
loads only its own data, paged and searched on the server. The tab is
in the URL (`?tab=keywords`), so a view is linkable and survives a
reload.

The page header carries the actions on every tab:

- **Sync now / Cancel run** — trigger a sync; a running sync can be
  cancelled and keeps the work completed so far.
- **Preview (dry run)** — what the next sync would do, without writing.
  It applies the same admission rules a real sync does, and is bounded
  to 60 seconds so a slow site can't hold the request open.
- **Rebake matching posts** — one click to catch existing posts up
  after an import: rebakes every post that may contain any active
  phrase, as one self-continuing background job in throttled batches
  (`sitemap_autolink_max_rebakes_per_job_run` per minute). Post
  content is never modified — only the rendered HTML refreshes.

The tabs:

- **Overview** — active rule count, entry count, phrases awaiting
  review, configuration warnings (e.g. entries whose type isn't
  currently allowed to link), and the result of the last dry run.
- **Keywords** — one row per phrase with the page it links to.
  Searches phrase text, destination title and URL; filters by state
  (with a count per state) and content type; approve, disable or
  delete a phrase inline. **Bulk actions address the whole current
  filter**, not just the rows on screen — a review queue of thousands
  is cleared in one confirmed click, and the confirmation names the
  exact count first. The review queue is this tab filtered to
  *Awaiting review*, and the tab badge carries its size.
- **Pages** — one card per ingested URL: linked title and type, its
  phrases as chips you can remove or restore, a field to add an alias,
  and the enable/disable toggle in the corner.
- **Conflicts** — two reports. *Duplicate phrases*: one phrase claimed
  by several pages, with the destination that actually wins marked.
  *Overlapping phrases*: phrases that sit inside a longer phrase, which
  therefore link less often than their catalog row suggests — the
  answer to "why didn't my three-word keyword fire".
- **Logs** — every sync run with its trigger, URL counts,
  added/retitled/removed counts, result (OK, Partial, Running,
  Interrupted, Failed), timing/telemetry notes, and errors.

A JSON management API (staff-only) backs all of it under
`/admin/plugins/discourse-sitemap-autolink/` — `status`, `entries`,
`terms`, `collisions`, `overlaps`, `runs`, `sync`, `rebake` — if you
prefer to script against it. Every list endpoint takes `page` and `q`;
the review queue is `terms?state=pending_review`.

Console tooling mirrors the page: `rake sitemap_autolink:report`,
`rake sitemap_autolink:preview[20]`, `rake sitemap_autolink:sync`.

## Settings

### Linking

| Setting | Default | Purpose |
| --- | --- | --- |
| `sitemap_autolink_enabled` | off | Master switch. |
| `sitemap_autolink_max_links_per_destination_per_post` | 1 | Times each destination may be linked per post (its most specific mention wins). 0 = unlimited. |
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
- **Strict about inputs.** Only absolute `http(s)` URLs are ingested —
  anything else in a `<loc>` is malformed (or malicious) and is
  counted as excluded. A sitemap index expands to at most 100 child
  sitemaps per source; a larger index is processed to the cap and the
  run records itself as **Partial**, so the unprocessed tail is never
  mistaken for deleted pages.
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
pending-review queue (approve it on the Keywords tab); is its content
type allowed by `sitemap_autolink_enabled_types`; is the post in an
excluded category; was the phrase already used up by the per-post
limits; does a higher-priority entry own the phrase (Conflicts →
duplicate phrases); does a longer phrase contain it, and did that
longer phrase appear too (Conflicts → overlapping phrases). The
Overview tab calls out the common misconfigurations.

**How do I undo everything?** Turn off `sitemap_autolink_enabled` and
rebake (`rake posts:rebake`, or let posts rebake naturally). Removing
the plugin afterwards leaves its three tables behind; drop them
manually if you want a spotless database.

## Development

```sh
# in a Discourse checkout with the plugin cloned into plugins/

# server-side specs (linking pipeline, sync, jobs, admin API):
LOAD_PLUGINS=1 bin/rspec plugins/discourse-sitemap-autolink/spec

# JavaScript acceptance tests (admin catalog page, click analytics):
bin/rake plugin:qunit['discourse-sitemap-autolink']
# …or in a browser, against a running dev server:
#   /tests?target=discourse-sitemap-autolink

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

`test/javascripts/acceptance/` covers the front end the same way, with
the plugin's JSON endpoints stubbed by pretender:

- `sitemap-autolink-admin-test.js` — the catalog page end to end: the
  nav tab the plugin registers, status/history/review-queue/entries
  rendering, syncing and cancelling, dry-run preview, the confirmed
  rebake wave, approving phrases one at a time and in bulk, search,
  filters, pagination, enabling/disabling entries and phrases, adding a
  manual alias, and the warnings shown for a misconfigured or
  unreachable catalog.
- `sitemap-autolink-analytics-test.js` — the optional GA4 tracking:
  clicking a generated link reports its type, phrase, destination and
  post; ordinary links and a disabled
  `sitemap_autolink_analytics_enabled` report nothing.

## License

MIT — see [LICENSE](LICENSE).

This repository's history began as a fork of
[discourse-linkify-words](https://github.com/discourse/discourse-linkify-words)
(MIT, © 2014 New Relic, Inc. and community maintainers). The plugin
was subsequently rewritten from scratch into the sitemap-driven system
documented here; the license and original copyright notice are
retained.
