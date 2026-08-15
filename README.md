# GBFans Auto Linkify (fork of discourse-linkify-words)

A fork of the official [discourse-linkify-words](https://github.com/discourse/discourse-linkify-words)
theme component, being extended into an automatic internal-linking system
for [GBFans.com](https://www.gbfans.com): forum posts automatically link the
first mention of shop products, Wiki articles, and other reference pages to
their canonical GBFans URLs.

## What it does today (Phase 1)

Everything the upstream component does — turn configured words, phrases, and
regexes in posts into links — plus **per-post link frequency limits**:

- **Each destination is linked at most once per post** (default). If a post
  mentions "elbow pads" five times, only the first mention becomes a link.
  Every post gets its own allowance; limits are never shared across a topic.
- Different terms are still linked independently within the same post.
- Aliases that point at the same URL share one allowance — the limit is
  counted **per destination URL**, not per configured entry.
- A configurable **total cap on auto-links per post** is supported
  (disabled by default) to keep long posts from becoming link farms.
- Overlapping matches are resolved deterministically: **leftmost match wins,
  then the longest (most specific) phrase**. If both `proton pack` and
  `Hasbro proton pack` are configured, "Hasbro proton pack" in a post links
  to the more specific entry.

Untouched, as before: existing manual links (`<a>`), `code`/`pre` content,
oneboxes, anything matched by `excluded_tags`/`excluded_classes`, and the
`word,url` / `/regex/i,url` settings format including `$1…$n` captures.

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `linked_words` | – | `word or phrase,URL` or `/regex/modifiers,URL` entries separated by `\|` |
| `max_links_per_term_per_post` | `1` | How many times each destination URL may be auto-linked in a single post. `0` = no per-post limit (legacy upstream behavior: words link once per paragraph, regexes link every occurrence). |
| `max_links_per_post` | `0` | Total auto-link budget per post across all terms. `0` = unlimited. |
| `excluded_tags` | `code\|pre` | HTML tags never linkified (`a` and `iframe` are always skipped) |
| `excluded_classes` | `onebox` | CSS classes never linkified (consider adding `quote` if quoted posts should not be linkified) |

## Development

```sh
pnpm install
pnpm test:unit   # matching-logic tests (Node, no Discourse needed)
pnpm lint
```

The matching pipeline lives in `javascripts/discourse-linkify/lib/utilities.js`:
candidates are collected per text node in document order, overlaps are
resolved deterministically, and a per-post `LinkCounter` enforces the
frequency limits before any DOM is modified.

## Roadmap

1. ~~Per-post link frequency limits~~ (done)
2. Catalog design: enumerate GBFans shop products and Wiki articles from
   authoritative sources (see `docs/`)
3. Generated draft catalog + collision/quality report
4. Dynamic catalog consumption with priorities, exclusions, and
   `gbfans-autolink*` CSS classes (default-off until vetted)
5. GA4 click analytics for automatic links
