# Technical assessment: server-side auto-linking in Discourse

Scope-change deliverable: verified answers to the six pre-implementation
questions, checked against Discourse source at `main` commit `739335d6`
(Aug 2026). forum.gbfans.com reports version **2026.8.0-latest.1**, i.e. it
tracks latest — current `main` is the right reference.

## 1. The correct plugin hook/API

**Recommendation: `on(:post_process_cooked) { |doc, post| … }`** — the
supported `DiscourseEvent` fired by `CookedPostProcessor`.

Mechanics, verified in source:

- Every post-process run **re-cooks from `Post#raw`**:
  `CookedPostProcessor#initialize` does `cooked = post.cook(post.raw, …);
  @doc = Loofah.html5_fragment(cooked)` (`lib/cooked_post_processor.rb:25-26`).
- `#post_process` fires `:before_post_process_cooked` before core
  processing and `:post_process_cooked` after it
  (`lib/cooked_post_processor.rb:36,50`), passing the **Loofah/Nokogiri
  doc** and the post. Mutating `doc` is the sanctioned pattern — bundled
  plugins do exactly this (`plugins/discourse-affiliate/plugin.rb:17`,
  `discourse-policy`, `discourse-events`, `footnote`).
- `Jobs::ProcessPost` then **persists the mutated doc**: when
  `cp.html` differs from the pre-existing cooked it runs
  `post.update_column(:cooked, cp.html)`, re-extracts `TopicLink`s, and
  publishes `:revised` to connected clients
  (`app/jobs/regular/process_post.rb:27-44`). `Post.raw` is never touched.
- We hook `:post_process_cooked` (not `before_`) so links are inserted
  **after** core's `enforce_nofollow` and `optimize_urls`
  (`lib/cooked_post_processor.rb:44-47`) — the plugin controls its own
  `rel`/attributes and core does not second-guess them.

**Invocation coverage — all four paths confirmed:**

| Path | Trigger |
| --- | --- |
| New post | `PostJobsEnqueuer` → `post.trigger_post_process(new_post: true)` (`lib/post_jobs_enqueuer.rb:41`) |
| Edit / re-cook | `PostRevisor` → `@post.trigger_post_process` (`lib/post_revisor.rb:861`) |
| Single rebake | `Post#rebake!` re-cooks, saves, then `trigger_post_process(bypass_bump: true)` (`app/models/post.rb:859-882`) |
| Bulk rebake | rake `posts:rebake*` / `Post.rebake_old` all funnel through `rebake!` → same hook |

**Reversibility is structural**: cooked is always regenerated from raw
before the hook runs, so a disabled/changed rule simply doesn't re-apply
on the next cook — rebaking removes or retargets generated links with no
cleanup pass. Idempotency is also structural: links can never stack,
because the hook never sees its own previous output.

One behavioral note: post-processing is asynchronous (Sidekiq), so a
freshly submitted post shows without auto-links for a few seconds until
`ProcessPost` runs and pushes the `:revised` update — identical to how
onebox/image processing already behaves. Auto-links do not appear in the
composer preview; that is acceptable and arguably desirable here.

## 2. How Watched Words "link" interacts with cooking — and why not use it

Watched words' replace/link actions run **inside the markdown-it engine**
(`frontend/discourse-markdown-it/src/features/watched-words.js`), on both
client preview and server cook, using per-action regexp lists compiled by
`WordWatcher` (`app/services/word_watcher.rb`, cached via
`Discourse.cache`, invalidated on change).

It is the right *architectural template* (rules applied at cook time from
a compiled cache; raw untouched; rebake picks up changes) but the wrong
*vehicle* for this system:

- Hard cap: `WatchedWord::MAX_WORDS_PER_ACTION = 2000`
  (`app/models/watched_word.rb:4`) — below the 5,000+ target.
- The matcher is a per-word regex loop with `MAX_MATCHES = 100`
  (`watched-words.js:1`) — exactly the O(words × post) scan to avoid.
- No metadata: no types, priorities, provenance, collision handling, no
  per-destination once-per-post policy, admin UX is a flat word list.

The plugin therefore reimplements the *pattern* (compiled cached matcher,
cook-time application) with its own storage and matcher, via the
post-process hook rather than inside markdown-it — which also keeps
matching in Ruby where the catalog lives, instead of serializing thousands
of patterns into the MiniRacer JS context on every cook.

## 3. Transforming cooked output without touching raw

Operate exclusively on the Loofah doc handed to the hook:

- Walk text nodes, skipping subtrees: `a`, `code`, `pre`, `iframe`,
  `aside.quote` (configurable — default skip, per preference), onebox
  containers, and anything with `data-gbfans-autolink` ancestors
  (belt-and-braces; structurally unnecessary).
- Attributes, URLs and emails are safe automatically: attribute values are
  not text nodes, and bare URLs/emails were already converted to `<a>` by
  markdown-it before the hook runs.
- Replace matched spans by splitting the text node into
  `text + <a class="gbfans-autolink …">match</a> + text`.
- The per-post frequency policy (once per destination, optional total cap)
  applies during this single pass in document order.

## 4. Selective historical rebaking

Direct core precedent: `Jobs::RebakeCustomEmojiPosts` does
`Post.where("raw LIKE ?", "%:#{name}:%").find_each(&:rebake!)`
(`app/jobs/regular/rebake_custom_emoji_posts.rb:6`); rake
`posts:rebake_match` uses the `Post.raw_match` scope the same way
(`lib/tasks/posts.rake:96`).

Plugin design mirrors it with rate limiting:

- Daily sync computes changed **active phrases** (added, retargeted,
  removed).
- Per phrase, enqueue a low-priority job that selects candidate posts with
  `Post.raw ILIKE %phrase%` (bounded batches, e.g. 200 posts/batch with
  sleep between batches, plus a per-day rebake budget setting) and calls
  `rebake!(priority: :low)` — never a blanket full-forum rebake.
- Admin actions: "rebake affected" (recorded phrase diffs) and "rebake
  all" (explicit button/rake task only).
- Removal/retarget cases search raw for the *old* phrase as well — the
  phrase text still sits in raw even when the rule is gone.

`ILIKE` on raw is a candidate *filter*, not the decision — the cook-time
matcher decides whether a link actually appears. Overmatching costs a
wasted rebake; undermatching only happens for phrases split by markdown
syntax (rare, self-heals on next organic edit/rebake).

## 5. Persistent catalog storage

**Plugin-owned ActiveRecord tables via plugin migrations** (standard
`db/migrate` support in plugins):

- `gbfans_autolink_entries`: canonical URL, title, content type, source
  sitemap, priority override, enabled, discovered-vs-manual origin,
  lastmod/content hash, first/last seen timestamps.
- `gbfans_autolink_terms`: entry_id, phrase, normalized phrase, state
  (`auto_active`, `pending_review`, `approved`, `disabled`), origin
  (`generated`, `manual`), uniqueness on normalized phrase per entry.

Rationale over `PluginStore`/site settings: thousands of rows, indexed
search for the admin surface, per-row state transitions, SQL joins for
collision reports, and Data Explorer compatibility for free. A compiled
"active ruleset" (normalized phrase → url/type/priority) is cached with a
version key in Redis (`Discourse.cache`) and memoized per process; any
entry/term mutation bumps the version — same invalidation pattern
`WordWatcher` uses.

## 6. Matcher for 5,000+ phrases

**Pure-Ruby Aho–Corasick automaton** over normalized text (lowercased,
typographic apostrophes folded), with word-boundary validation and
leftmost-longest-then-priority resolution on the emitted candidates:

- One scan per post regardless of phrase count — O(text length), no
  per-phrase regexes.
- Built from the active ruleset and cached per process keyed by catalog
  version; build cost for ~5–10k phrases is well under a second and is
  paid only when the catalog changes.
- No gem dependency (small vendored implementation, ~100 lines), so
  nothing to add to Discourse's Gemfile.
- Benchmarked in `script/benchmark_matcher.rb` with a 5,000+ phrase
  catalog against realistic post lengths (results in the plugin README).

Regex-based alternation (the theme-component approach) was rejected
server-side: Ruby's regex engine has no irregexp-style alternation
optimization, and a 5k-alternative pattern is both slow and fragile.

## Proof-of-concept definition

The PoC ships as the plugin skeleton with matching driven by a
`gbfans_autolink_test_mappings` site setting (`phrase|url|type` list —
"elbow pads" → shop URL), plus rspec specs asserting, via the real
create/edit/rebake pipeline:

1. raw unchanged, cooked contains the link with `gbfans-autolink` markup;
2. only the first occurrence per post links; separate posts get their own
   allowance; total cap honored;
3. edit and `rebake!` re-apply links;
4. removing the mapping + rebake removes the link;
5. `a`/`code`/`pre`/quote content untouched; manual links untouched.

The catalog/sitemap machinery then feeds the same ruleset interface the
test mappings use, so the PoC path stays valid permanently.
