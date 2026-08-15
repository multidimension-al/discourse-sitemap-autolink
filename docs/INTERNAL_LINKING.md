> **Note:** this design document predates the repo becoming plugin-only.
> The theme component and tools/catalog generator it references were
> removed from the tip and live at the git tag `theme-component-archive`;
> the plugin at the repository root implements the same architecture
> server-side.

# GBFans internal-linking system — content sources & catalog design

Phase 2 deliverable: what the GBFans.com application actually exposes, which
source the link catalog should be built from, and the architecture for the
catalog → theme pipeline. Findings below were gathered live from
www.gbfans.com in August 2026.

## 1. What the application exposes today

GBFans.com is a custom Next.js (App Router) application. The public surface
relevant to a link catalog:

### Segmented sitemaps (application-generated)

`https://www.gbfans.com/sitemap.xml` is a sitemap **index** whose children are
already split by content type — classification comes from the application
itself, not from URL-pattern guessing:

| Sitemap | URLs (Aug 2026) | URL shape | Autolink candidate? |
| --- | --- | --- | --- |
| `sitemaps/shop-products.xml` | 572 | `/shop/<slug>` | ✅ products |
| `sitemaps/shop-categories.xml` | 67 | `/shop/catalog/<slug>` | ✅ categories |
| `sitemaps/wiki.xml` | 2,971 | `/wiki/<section…>/<slug>` | ✅ wiki (vet first) |
| `sitemaps/franchises.xml` | 347 | `/fans/franchises/<slug>` | ⚠️ optional, off by default |
| `sitemaps/franchise-guides.xml` | 16 | `/fans/franchises/guides/…` | ❌ |
| `sitemaps/news.xml`, `blog.xml`, `pages.xml`, `fiction.xml`, `events.xml`, `profiles.xml`, `gallery-*.xml`, `fan-props.xml`, `fan-art.xml` | – | – | ❌ not reference content |

The wiki sitemap carries `lastmod`, which enables incremental refresh.

### Page metadata (exact titles)

Slugs are **lossy** — titles cannot be reliably derived from URLs:

- `/shop/14-split-wire-loom` → real name `Pack: 1/4" Split Wire Loom`
- `/wiki/tobins-spirit-guide` → real title `Tobin's Spirit Guide` (a post
  says "Tobin's" with an apostrophe; the slug has none)

Every product page embeds schema.org JSON-LD (`@type: Product`) with the
exact `name`, plus `og:title` and `<title>` (`… - GBFans.com Shop` suffix).
Wiki/other pages expose `og:title`/`<title>` similarly. So exact titles are
obtainable per URL without parsing visible HTML.

> Bug noticed while inspecting: the Product JSON-LD on product pages emits
> `"description": "[object Object]"` — a serialization bug in the app worth
> fixing independently of this project.

Product names use a `<Line>: <Name>` prefix convention (`Pack: ALICE Frame
Padding`, `Pack: Clippard Brass Elbow`). The part after the colon is what
people actually type in posts — alias generation must strip the prefix.

### APIs

- `GET /api/search?q=…` → **200**, rich JSON: sections `products` (title,
  url, categories, availability, stock, price), `content` (title, url,
  `type: wiki|news|…`), `fanContent`, `gallery`, `fans`. Exact titles and
  even availability — but it is a paginated *search* endpoint, not an
  enumeration endpoint.
- `POST(?) /api/wiki/pages` → GET returns **405** (endpoint exists,
  non-GET). Worth checking in the app codebase whether it can enumerate
  wiki pages.
- The site's WAF rejects generic client user agents (Python urllib got 403;
  curl passed). Any fetcher must send an identifying User-Agent.

### Forum

The Discourse forum lives at **forum.gbfans.com** — a different origin from
www.gbfans.com. Anything the theme component fetches at runtime must either
be served with CORS headers or be uploaded to the Discourse instance itself.

## 2. Recommended authoritative source

**End state (recommended): a first-party catalog export from the app.**
The application already runs enumeration queries for the segmented sitemaps
and feeds a search index with exact titles, types and availability. A small
addition to the app — a scheduled job or endpoint (e.g.
`/api/autolink-catalog`) that emits every product, shop category and wiki
article as `{title, url, type, availability}` — is the cleanest source:
exact titles straight from the database, no scraping, one request. The code
that generates `sitemaps/shop-products.xml` and powers `/api/search` is the
place to borrow from.

**Until that exists (implemented in Phase 3): sitemaps + page metadata.**
The generator in `tools/catalog/` enumerates URLs from the segmented
sitemaps (authoritative, application-generated, classified) and resolves
exact titles from each page's JSON-LD/og:title, with:

- an on-disk cache keyed by URL (+ `lastmod` where present) so the backfill
  of ~3,600 pages happens once and refreshes touch only changed pages;
- polite fetching (identifying UA, capped concurrency, head-only reads);
- the same output format the first-party export would produce, so swapping
  the source later changes nothing downstream.

Rejected as the backbone: raw sitemap URLs alone (no titles), `/api/search`
(pagination, search-backend load, not an enumeration), scraping category
listing pages (pagination + duplicates).

## 3. Catalog data model

### Authoring/source format (one JSON per entry, human-mergeable)

```json
{
  "title": "Pack: ALICE Frame Padding",
  "url": "/shop/alice-frame-padding",
  "type": "product",
  "aliases": ["ALICE Frame Padding", "ALICE frame pads"],
  "priority": null,
  "enabled": true,
  "availability": "in_stock",
  "source": "sitemap:shop-products"
}
```

- `aliases` are generated (see §4) and extendable by hand via
  `tools/catalog/overrides.json` (manual aliases, exclusions, URL
  overrides, disabled entries, priority bumps). Overrides always win.
- `priority: null` means "use the type's default rank".

### Compiled client format (what the theme downloads)

Compact arrays, minified — no per-entry objects:

```json
{
  "v": 1,
  "generated": "2026-08-15T…",
  "types": ["product", "category", "wiki"],
  "entries": [["/shop/alice-frame-padding", 0], …],
  "aliases": { "alice frame padding": 17, "elbow pads": 42, … }
}
```

`aliases` maps a lowercased alias to an entry index; entries carry URL and
type index. The Phase 3 report measures the real payload size (target: low
hundreds of KB raw, tens of KB gzipped — it rides the CDN with a long TTL).

## 4. Alias generation & safety rules

Normalization: lowercase, straight/curly apostrophes unified, `&`↔`and`
variants, whitespace collapsed. Generated aliases per entry:

1. the full title;
2. product titles minus the `<Line>:` prefix (`Pack: ALICE Frame Padding` →
   `ALICE Frame Padding`);
3. title minus trailing parenthetical (`Clippard Brass Elbow (GB1 Ion Arm)`
   → also, the parenthetical-free base *if it doesn't collide*);
4. trivial plural/singular `s` variants where unambiguous.

Safety gates (all configurable in the generator config):

- **minimum alias length** (default 5 chars) and minimum word count for
  wiki titles (default: single-word wiki titles are *flagged, not enabled*);
- **stoplist** of generic terms that must never auto-link ("pack", "belt",
  "patch", "uniform", "slime", …) — seeded in `overrides.json`, grown from
  each report's "suspicious terms" section;
- entries can be `enabled: false` individually; whole types can be disabled
  in the theme (wiki stays off until its slice of the catalog is vetted).

## 5. Collisions & priority

When one alias maps to multiple destinations the winner is chosen
**deterministically at compile time** and the loser recorded in the report:

1. manual override (explicit alias in `overrides.json`)
2. product
3. shop category
4. wiki article
5. general content

The ranking is a config array, not code. Ties inside a rank: longer title
wins, then lexicographically smaller URL (stable builds). At *match* time
the runtime rule (already shipped in Phase 1) is leftmost match, then
longest phrase — so `Hasbro proton pack` beats `proton pack` when both
could match the same text.

## 6. Runtime consumption (Phase 4)

- New theme settings: `catalog_url` (default empty = feature off),
  `catalog_types` (which types actually link), `catalog_refresh_hours`
  (localStorage TTL). Manual `linked_words` entries keep working unchanged
  and always outrank catalog matches.
- The catalog is fetched **once per browser session** (localStorage cache
  with TTL + version key), never per post. The URL must be CORS-readable
  from forum.gbfans.com — either set CORS on the bucket/route serving it,
  or upload the JSON to Discourse itself and point the setting at the
  upload URL.
- Matching uses **one combined case-insensitive regex** over all aliases
  (alternation sorted longest-first, same word-boundary rules as Phase 1)
  plus a hash lookup from matched text → entry. One regex pass per text
  node regardless of catalog size — never thousands of per-entry scans.
- Catalog links get `gbfans-autolink gbfans-autolink-<type>` classes,
  internal-friendly attributes (same-tab navigation, no `nofollow`), and
  share the Phase 1 per-post limits (one link per destination per post,
  optional total cap).

## 7. Refresh mechanism

Daily (or on-demand) cron wherever GBFans runs scheduled jobs:

```
node tools/catalog/build-catalog.mjs --config tools/catalog/config.json
   → catalog build + report
upload catalog.json to stable URL (e.g. the existing gbfans-public GCS
   bucket or a /autolink-catalog.json app route), CDN TTL ~1h + ETag
```

Clients pick the new catalog up on their next TTL expiry. No Discourse
deploy is involved in a refresh; theme updates are only needed for logic
changes. When the first-party export (§2) lands, only the generator's
*input* stage changes.

## 8. Analytics (Phase 5)

No tracking query parameters on canonical URLs. A delegated click listener
on `a.gbfans-autolink` pushes a GA4 event (`gtag`/`dataLayer` when present):

```
event: gbfans_autolink_click
  link_type: product | category | wiki
  link_term: the matched alias
  link_url:  the destination path
  topic_id / post_number: source location in the forum
```

With `link_type` and `link_url` registered as custom dimensions, GA4
answers: clicks by type, top terms, source topics driving shop traffic;
purchase attribution comes from standard GA4 ecommerce reporting on
sessions containing the event (or a BigQuery join for term-level revenue).

## 9. Rollout

1. ✅ Phase 1 — per-post limits (shipped, works with manual `linked_words`)
2. ✅ Phase 2 — this document
3. Phase 3 — generator + draft catalog + collision/suspicious-term report
   (`tools/catalog/`)
4. Phase 4 — catalog consumption behind `catalog_url` (default off);
   enable products/categories first, wiki only after its report is vetted
5. Phase 5 — analytics instrumentation

Manual `linked_words` mappings are never replaced by any of this — they
keep working and keep priority until GBFans decides otherwise.
