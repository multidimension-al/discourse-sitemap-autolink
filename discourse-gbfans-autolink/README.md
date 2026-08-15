# discourse-gbfans-autolink

Server-side automatic internal linking for GBFans.com: posts link the
first mention of shop products, categories and wiki articles to their
canonical GBFans URLs, during Discourse's normal cooking/rebaking —
`Post.raw` is never modified, `Post.cooked` gets normal reversible links.

> Currently developed inside the `discourse-linkify-words` fork repo;
> move this directory to its own repository before installing
> (Discourse installs plugins from a repo root).
> Design rationale and verified extension points:
> `docs/PLUGIN_ASSESSMENT.md` and `docs/INTERNAL_LINKING.md` in the
> repo root.

## How it works

- **Linking** happens in `on(:post_process_cooked)`: CookedPostProcessor
  re-cooks from raw, hands the plugin a Loofah doc, the plugin inserts
  links, and `Jobs::ProcessPost` persists the result. Create, edit,
  `rebake!` and bulk rebakes all funnel through this hook, so disabling
  a rule + rebaking removes its links, structurally.
- **Matching** is one Aho–Corasick scan per post over a compiled,
  cached ruleset (rebuilt only when the catalog version bumps). With the
  real 5,171-phrase GBFans catalog: automaton build ~120 ms (cached),
  ~0.7 ms per 2 KB post, full parse+scan+rewrite ~1.9 ms — measured via
  `ruby script/benchmark_matcher.rb ../tools/catalog/dist/catalog.json`.
- **Ingestion** is a daily scheduled job (`gbfans_autolink_daily_sync`)
  that fetches the configured child sitemaps, diffs against the stored
  catalog (new/changed/removed/unchanged via URL + `lastmod`), fetches
  pages for titles **only** for new/changed URLs, regenerates terms, and
  optionally enqueues selective rebakes. Post cooking never fetches
  anything.
- **Safety**: generated terms pass gates (min length, generic-word list,
  single-word wiki holdback with letter+digit exception, global excluded
  terms). Anything questionable lands in `pending_review` instead of
  linking. Manual terms always outrank generated ones; the global
  excluded list does not apply to explicit manual aliases.
- **Priorities**: alias collisions resolve deterministically by
  `gbfans_autolink_type_priority` (manual > product > category > wiki >
  content by default), and at match time longer phrases beat shorter
  overlapping ones ("Hasbro Proton Pack" > "Proton Pack").
- **Markup**: `<a class="gbfans-autolink gbfans-autolink-<type>"
  data-gbfans-autolink="true" data-gbfans-link-type="…"
  data-gbfans-term="…" data-gbfans-link-id="…">` — canonical URLs, no
  tracking parameters. A tiny client initializer (optional, isolated)
  sends `internal_auto_link_click` GA4 events via `gtag`/`dataLayer`.

## Proof of concept / migration path

1. Install the plugin, leave `gbfans_autolink_enabled` **off** in
   production until tested on staging.
2. Set `gbfans_autolink_test_mappings`, e.g.:
   `elbow pads,/shop/grey-elbow-pads,product`
   `Alice frame padding,/shop/alice-frame-padding,product`
3. Enable the plugin and verify (specs cover all of these, see below):
   raw unchanged; first occurrence linked once per post; edits keep
   working; `post.rebake!` applies/removes/retargets links as mappings
   change; quotes/code/manual links untouched.
4. Remove the equivalent entries from the discourse-linkify-words theme
   component's `linked_words` so nothing double-links.
5. Enable `gbfans_autolink_daily_sync_enabled` to populate the catalog
   from sitemaps; review pending terms and collisions via the admin API;
   enable `wiki` in `gbfans_autolink_enabled_types` only after review.
6. Retire the theme component when no manual mappings remain.

## Settings

All in Admin → Settings → Plugins, `gbfans autolink` filter. Highlights:

| Setting | Default | Purpose |
| --- | --- | --- |
| `gbfans_autolink_enabled` | off | master switch |
| `gbfans_autolink_test_mappings` | – | manual `phrase,url,type` rules |
| `gbfans_autolink_max_links_per_destination_per_post` | 1 | once per destination per post |
| `gbfans_autolink_max_links_per_post` | 0 | total cap per post (0 = unlimited) |
| `gbfans_autolink_skip_quotes` | on | don't link inside quoted material |
| `gbfans_autolink_enabled_types` | manual, product, category | wiki off until vetted |
| `gbfans_autolink_daily_sync_enabled` | off | sitemap → catalog job |
| `gbfans_autolink_auto_rebake_on_changes` | off | selective rebakes after sync |
| `gbfans_autolink_excluded_terms` | pack, belt, … | never auto-generate these |

## Administration

JSON management API (staff only) under
`/admin/plugins/gbfans-autolink/…`: `status`, `entries` (search/filter/
paginate), entry create/update (enable/disable, priority, URL override),
term create/update/delete (add aliases, approve `pending_review`,
disable), `collisions`, `pending`, `sync`, `rebuild`, `rebake`
(per-phrase selective; full-forum deliberately stays with
`rake posts:rebake`). See `app/controllers/gbfans_autolink_admin_controller.rb`
for parameters. A dedicated admin UI page can be layered on top of these
endpoints later; the API plus Data Explorer already avoids any
hand-editing of JSON.

## Development

```sh
# in a Discourse checkout with this plugin symlinked/cloned into plugins/
LOAD_PLUGINS=1 bin/rspec plugins/discourse-gbfans-autolink/spec

# dependency-free checks (no Discourse needed):
ruby script/local_check.rb          # matcher + HTML applier behavior
ruby script/benchmark_matcher.rb    # performance with a real catalog
```

`spec/integration/gbfans_autolink_cooking_spec.rb` is the
proof-of-concept contract: creation, editing, rebake-applies,
rebake-removes, rebake-retargets, caps, quote/code/manual-link safety,
catalog-driven linking, pending-review gating, and wiki staying dark
until enabled.
