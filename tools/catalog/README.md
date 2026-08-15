# GBFans autolink catalog generator

Offline tool that turns GBFans.com's segmented sitemaps into a reviewed,
compiled internal-link catalog plus a quality report. Architecture and
source rationale: `docs/INTERNAL_LINKING.md`. The server-side Discourse
plugin consumes the same sources; this tool is also the reference
implementation of the alias/safety/collision rules.

## Usage

```sh
node tools/catalog/build-catalog.mjs                 # full build (uses .cache)
node tools/catalog/build-catalog.mjs --max-pages=25  # smoke test
node tools/catalog/build-catalog.mjs --types=product,category
node tools/catalog/build-catalog.mjs --no-fetch      # cache/slug titles only
node tools/catalog/build-catalog.mjs --refetch       # ignore title cache
```

Behind a corporate proxy, Node needs `NODE_USE_ENV_PROXY=1` (and a CA via
`NODE_EXTRA_CA_CERTS`); in normal environments no env vars are needed.

Outputs in `dist/`:

- `catalog.json` — compact compiled catalog (what a client would consume)
- `catalog-source.json` — full authoring view: every entry with title,
  aliases, flags, provenance
- `report.md` — inventory counts, collisions, suspicious terms, gate
  stats, fetch failures, payload size

Page titles are cached in `.cache/titles.json` (gitignored); only new or
`lastmod`-changed pages are refetched on later runs.

## Tuning

- `config.json` — sources, type priority, `minAliasLength`,
  `minWikiTitleWords`, `excludeCommonSingleWords`, fetch politeness.
- `overrides.json` — the human knobs, always winning over generation:
  - `excludedAliases`: terms that must never link ("pack", "uniform", …)
  - `manualAliases`: `{ "elbow pads": "/shop/some-product" }`
  - `urlOverrides`, `disabled`, `priorityOverrides`, `extraEntries`

Workflow: run a build, read `report.md` (collisions + suspicious terms +
held-back single-word wiki titles), grow `overrides.json`, rebuild.
