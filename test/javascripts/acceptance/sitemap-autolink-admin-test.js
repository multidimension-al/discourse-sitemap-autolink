import { click, currentURL, fillIn, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";
import { i18n } from "discourse-i18n";

const PLUGIN_ID = "discourse-sitemap-autolink";
const BASE = `/admin/plugins/${PLUGIN_ID}`;
const OVERVIEW = `${BASE}/overview`;
const SITEMAPS = `${BASE}/sitemaps`;
const KEYWORDS = `${BASE}/keywords`;
const CONFLICTS = `${BASE}/conflicts`;
const LOGS = `${BASE}/logs`;

function pluginPayload() {
  return {
    id: PLUGIN_ID,
    name: PLUGIN_ID,
    humanized_name: "Sitemap Autolink",
    about: "Automatically links your site's pages.",
    version: "1.0.0",
    url: "https://github.com/multidimension-al/discourse-sitemap-autolink",
    enabled: true,
    enabled_setting: "sitemap_autolink_enabled",
    has_settings: true,
    admin_route: {
      label: "sitemap_autolink.title",
      location: PLUGIN_ID,
      use_new_show_route: true,
    },
  };
}

function statusPayload(overrides = {}) {
  return {
    enabled: true,
    sync_enabled: true,
    sources_configured: true,
    catalog_version: 42,
    active_rules: 3,
    entries: 2,
    active_entries: 2,
    terms: 4,
    pending_terms: 2,
    entry_types: ["product", "wiki"],
    pending_sitemaps: 0,
    enabled_types_setting: "product|wiki",
    stats: {
      pages: {
        total: 3,
        live: 2,
        disabled: 0,
        gone: 1,
        manual: 0,
        by_type: { product: 1, wiki: 1 },
      },
      keywords: {
        total: 4,
        auto_active: 1,
        approved: 1,
        pending_review: 2,
        disabled: 0,
        manual: 1,
      },
      rules: 3,
      contested: 1,
      sitemaps: { imported: 2, pending: 0, ignored: 1, indexes: 1 },
    },
    last_run: null,
    ...overrides,
  };
}

function runsPayload() {
  return [
    {
      id: 2,
      started_at: "2026-08-16T10:00:00.000Z",
      finished_at: "2026-08-16T10:04:00.000Z",
      success: true,
      partial: false,
      result: "ok",
      triggered_by: "manual",
      urls_seen: 120,
      urls_excluded: 4,
      entries_added: 6,
      entries_retitled: 1,
      entries_removed: 2,
      phrases_added: 9,
      phrases_removed: 3,
      error_details: null,
      sources: ["https://example.com/sitemap.xml"],
    },
    {
      id: 1,
      started_at: "2026-08-15T10:00:00.000Z",
      finished_at: "2026-08-15T10:01:00.000Z",
      success: false,
      partial: false,
      result: "failed",
      triggered_by: "scheduled",
      urls_seen: 0,
      urls_excluded: 0,
      entries_added: 0,
      entries_retitled: 0,
      entries_removed: 0,
      phrases_added: 0,
      phrases_removed: 0,
      error_details: "failed to fetch sitemap https://example.com/sitemap.xml",
      sources: ["https://example.com/sitemap.xml"],
    },
  ];
}

function term(id, phrase, state, overrides = {}) {
  return {
    id,
    entry_id: 11,
    phrase,
    normalized_phrase: phrase.toLowerCase(),
    state,
    origin: "generated",
    review_reason: null,
    duplicate: false,
    ...overrides,
  };
}

function entriesPayload() {
  return {
    total: 2,
    page: 0,
    per_page: 50,
    pages: 2,
    types: ["product", "wiki"],
    sitemaps: [
      "https://example.com/sitemap-products.xml",
      "https://example.com/sitemap-wiki.xml",
    ],
    state_counts: {
      auto_active: 1,
      pending_review: 1,
      approved: 1,
      disabled: 1,
    },
    linking_count: 2,
    gone_pages: 0,
    entries: [
      {
        id: 11,
        url: "https://example.com/shop/widget-kit",
        title: "Widget Kit",
        content_type: "product",
        priority: 0,
        enabled: true,
        auto_discovered: true,
        removed_from_source: false,
        title_source: "title",
        source: "sitemap",
        sitemaps: [
          "https://example.com/sitemap-featured.xml",
          "https://example.com/sitemap-products.xml",
        ],
        last_seen_at: "2026-08-16T10:00:00.000Z",
        terms: [
          term(101, "Widget Kit", "approved", { duplicate: true }),
          term(102, "widget kits", "disabled"),
          term(103, "Kit", "pending_review", {
            review_reason: "phrase is a single common word",
          }),
          term(104, "Deluxe Widget Kit", "auto_active", { origin: "manual" }),
        ],
      },
      {
        id: 12,
        url: "https://example.com/wiki/gasket-set",
        title: "gasket-set",
        content_type: "wiki",
        priority: 0,
        enabled: true,
        auto_discovered: true,
        removed_from_source: false,
        title_source: "slug",
        source: "sitemap",
        sitemaps: ["https://example.com/sitemap-wiki.xml"],
        last_seen_at: "2026-08-16T10:00:00.000Z",
        terms: [term(105, "gasket set", "approved", { entry_id: 12 })],
      },
    ],
  };
}

function collisionsPayload() {
  return {
    total: 1,
    page: 0,
    per_page: 50,
    pages: 1,
    competing: 1,
    settled: 4,
    include_inactive: false,
    collisions: [
      {
        phrase: "widget kit",
        winner: "https://example.com/shop/widget-kit",
        linking_candidates: 2,
        candidates: [
          {
            term_id: 11,
            entry_id: 1,
            url: "https://example.com/shop/widget-kit",
            title: "Widget Kit",
            type: "product",
            state: "auto_active",
            page_state: "live",
            linking: true,
            reason: null,
            can_win: true,
            winner: true,
          },
          {
            term_id: 12,
            entry_id: 2,
            url: "https://example.com/wiki/widget-kit",
            title: "Accessories: Widget Kit",
            type: "wiki",
            state: "auto_active",
            page_state: "live",
            linking: true,
            reason: null,
            can_win: true,
            winner: false,
          },
          {
            term_id: 13,
            entry_id: 3,
            url: "https://example.com/old/widget-kit",
            title: "Widget Kit (retired)",
            type: "wiki",
            state: "auto_active",
            page_state: "removed",
            linking: false,
            reason: "page_gone",
            can_win: false,
            winner: false,
          },
        ],
      },
    ],
  };
}

function overlapsPayload() {
  return {
    total: 2,
    page: 0,
    per_page: 50,
    pages: 1,
    truncated: false,
    same_destination: 6,
    settled: 2,
    include_inactive: false,
    overlaps: [
      {
        phrase: "widget kit",
        linking: true,
        owners: [
          {
            entry_id: 1,
            url: "https://example.com/shop/widget-kit",
            title: "Widget Kit",
            type: "product",
            state: "approved",
            page_state: "live",
            linking: true,
            reason: null,
          },
        ],
        covered_by: [
          {
            phrase: "acme widget kit gasket set",
            linking: true,
            owners: [
              {
                entry_id: 4,
                url: "https://example.com/shop/acme-widget-kit-gasket-set",
                title: "Acme Widget Kit Gasket Set",
                type: "product",
                state: "auto_active",
                page_state: "live",
                linking: true,
                reason: null,
              },
            ],
          },
        ],
      },
      {
        phrase: "gasket set",
        linking: false,
        owners: [
          {
            entry_id: 12,
            url: "https://example.com/wiki/gasket-set",
            title: "gasket-set",
            type: "wiki",
            state: "pending_review",
            page_state: "live",
            linking: false,
            reason: "keyword_pending",
          },
        ],
        covered_by: [
          {
            phrase: "acme widget kit gasket set",
            linking: true,
            owners: [
              {
                entry_id: 4,
                url: "https://example.com/shop/acme-widget-kit-gasket-set",
                title: "Acme Widget Kit Gasket Set",
                type: "product",
                state: "auto_active",
                page_state: "live",
                linking: true,
                reason: null,
              },
            ],
          },
        ],
      },
    ],
  };
}

function sitemapsPayload() {
  return {
    pending: 1,
    auto_import: false,
    configured_sources: ["https://example.com/sitemap.xml,product"],
    sitemaps: [
      {
        id: 1,
        url: "https://example.com/sitemap.xml",
        parent_url: null,
        content_type: "product",
        kind: "index",
        status: "enabled",
        configured: true,
        url_count: 0,
        url_count_partial: false,
        last_seen_at: "2026-08-16T10:00:00.000Z",
        last_fetched_at: "2026-08-16T10:00:00.000Z",
        last_error: null,
        entries: 0,
        live_entries: 0,
        gone_entries: 0,
        children: 2,
        children_imported: 1,
        children_pending: 1,
        children_ignored: 0,
      },
      {
        id: 2,
        url: "https://example.com/sitemap-products.xml",
        parent_url: "https://example.com/sitemap.xml",
        content_type: "product",
        kind: "urlset",
        status: "enabled",
        configured: false,
        url_count: 1400,
        url_count_partial: false,
        last_seen_at: "2026-08-16T10:00:00.000Z",
        last_fetched_at: "2026-08-16T10:00:00.000Z",
        last_error: null,
        entries: 1400,
        live_entries: 1398,
        gone_entries: 2,
        children: 0,
        children_imported: 0,
        children_pending: 0,
        children_ignored: 0,
      },
      {
        id: 3,
        url: "https://example.com/sitemap-tags.xml",
        parent_url: "https://example.com/sitemap.xml",
        content_type: "product",
        kind: "urlset",
        status: "pending",
        configured: false,
        url_count: 41000,
        url_count_partial: true,
        last_seen_at: "2026-08-16T10:00:00.000Z",
        last_fetched_at: "2026-08-16T10:00:00.000Z",
        last_error: null,
        entries: 0,
        live_entries: 0,
        gone_entries: 0,
        children: 0,
        children_imported: 0,
        children_pending: 0,
        children_ignored: 0,
      },
    ],
  };
}

function previewPayload() {
  return {
    errors: [],
    sources: [
      {
        sitemap: "https://example.com/sitemap.xml",
        type: "product",
        total_urls: 120,
        excluded_by_pattern: 4,
        excluded_sample: ["https://example.com/shop/cart"],
        sampled: [
          {
            url: "https://example.com/shop/widget-kit",
            title: "Widget Kit",
            title_source: "title",
            phrases: [
              { phrase: "Widget Kit", state: "approved", reason: null },
              {
                phrase: "kit",
                state: "pending_review",
                reason: "phrase shorter than 5 characters",
              },
            ],
          },
        ],
      },
    ],
  };
}

// Server state and the requests each page made, rebuilt before every
// test so one test's clicks can never leak into the next.
let state;
let requests;

function record(name, request, helper) {
  requests.push({
    name,
    url: request.url,
    queryParams: request.queryParams,
    raw: request.requestBody,
    body: helper.parsePostData(request.requestBody),
  });
}

function lastRequest(name) {
  return requests.filter((r) => r.name === name).pop();
}

function resetState() {
  state = {
    status: statusPayload(),
    runs: runsPayload(),
    entries: entriesPayload(),
    collisions: collisionsPayload(),
    overlaps: overlapsPayload(),
    sitemaps: sitemapsPayload(),
  };
  requests = [];
}

function stubReads(server, helper, { status } = {}) {
  server.get(`${BASE}.json`, () => helper.response(pluginPayload()));
  server.get(`${BASE}/status`, () =>
    status ? status() : helper.response(state.status)
  );
  server.get(`${BASE}/runs`, () => helper.response({ runs: state.runs }));
  server.get(`${BASE}/collisions`, (request) => {
    record("collisions", request, helper);
    return helper.response(state.collisions);
  });
  server.get(`${BASE}/overlaps`, (request) => {
    record("overlaps", request, helper);
    return helper.response(state.overlaps);
  });
  server.get(`${BASE}/sitemaps/list`, (request) => {
    record("sitemaps", request, helper);
    return helper.response(state.sitemaps);
  });

  server.get(`${BASE}/entries`, (request) => {
    record("entries", request, helper);
    const { q, state: stateFilter } = request.queryParams;
    let matching = state.entries.entries;
    if (q) {
      matching = matching.filter((entry) =>
        `${entry.title} ${entry.url} ${entry.terms.map((t) => t.phrase).join(" ")}`
          .toLowerCase()
          .includes(q.toLowerCase())
      );
    }
    if (stateFilter) {
      matching = matching.filter((entry) =>
        entry.terms.some((t) => t.state === stateFilter)
      );
    }
    return helper.response({
      ...state.entries,
      total: matching.length,
      entries: matching,
    });
  });
}

acceptance("Sitemap Autolink | Admin | navigation", function (needs) {
  needs.user();
  needs.settings({ sitemap_autolink_enabled: true });
  needs.hooks.beforeEach(resetState);
  needs.pretender((server, helper) => stubReads(server, helper));

  test("each concern is its own page in the plugin nav", async function (assert) {
    await visit(OVERVIEW);

    const nav = ".admin-plugin-config-page__top-nav-item a";

    ["overview", "sitemaps", "keywords", "conflicts", "logs"].forEach(
      (page) => {
        assert
          .dom(`${nav}[href="${BASE}/${page}"]`)
          .hasText(i18n(`sitemap_autolink.admin.nav.${page}`));
      }
    );

    assert
      .dom(`${nav}[href="${BASE}/catalog"]`)
      .doesNotExist("the single Catalog page it replaced is gone");
  });

  test("each page loads its own data when opened", async function (assert) {
    await visit(OVERVIEW);
    assert.notOk(lastRequest("entries"), "the overview does not load keywords");

    await click(
      `.admin-plugin-config-page__top-nav-item a[href="${KEYWORDS}"]`
    );
    assert.strictEqual(currentURL(), KEYWORDS);
    assert
      .dom(".sitemap-autolink-admin__entry")
      .exists({ count: 2 }, "arriving from the nav loads the keyword list");

    await click(
      `.admin-plugin-config-page__top-nav-item a[href="${CONFLICTS}"]`
    );
    assert.ok(
      lastRequest("collisions"),
      "and moving on loads the next page's data"
    );
    assert.dom(".sitemap-autolink-admin__collision").exists();
  });

  test("the old catalog URL still works", async function (assert) {
    await visit(`${BASE}/catalog`);

    assert.strictEqual(
      currentURL(),
      OVERVIEW,
      "it redirects to the overview instead of 404ing"
    );
  });
});

acceptance("Sitemap Autolink | Admin | keywords", function (needs) {
  needs.user();
  needs.settings({ sitemap_autolink_enabled: true });
  needs.hooks.beforeEach(resetState);

  needs.pretender((server, helper) => {
    stubReads(server, helper);

    server.put(`${BASE}/terms/bulk`, (request) => {
      record("bulk", request, helper);
      state.entries = { ...entriesPayload(), total: 0, entries: [] };
      return helper.response({ success: "OK", updated: 4 });
    });

    server.put(`${BASE}/terms/:id`, (request) => {
      record("term", request, helper);
      const id = parseInt(request.params.id, 10);
      const existing = state.entries.entries
        .flatMap((e) => e.terms)
        .find((t) => t.id === id);
      return helper.response({
        ...existing,
        state: helper.parsePostData(request.requestBody).state,
      });
    });

    server.delete(`${BASE}/terms/:id`, (request) => {
      record("delete-term", request, helper);
      return helper.response({ success: "OK" });
    });

    server.post(`${BASE}/terms`, (request) => {
      record("create-term", request, helper);
      const data = helper.parsePostData(request.requestBody);
      return helper.response(
        term(999, data.phrase, "approved", {
          entry_id: parseInt(data.entry_id, 10),
          origin: "manual",
        })
      );
    });

    server.put(`${BASE}/entries/:id`, (request) => {
      record("entry", request, helper);
      const id = parseInt(request.params.id, 10);
      const entry = state.entries.entries.find((e) => e.id === id);
      return helper.response({
        ...entry,
        enabled: helper.parsePostData(request.requestBody).enabled === "true",
      });
    });

    server.delete(`${BASE}/entries/purge`, (request) => {
      record("purge", request, helper);
      state.entries = { ...state.entries, gone_pages: 0 };
      return helper.response({ success: "OK", purged: 2 });
    });

    server.delete(`${BASE}/entries/:id`, (request) => {
      record("purge-entry", request, helper);
      return helper.response({ success: "OK" });
    });
  });

  // The whole point of the page: find what points at a given URL. A row
  // per keyword cannot answer that; a card per page can.
  test("groups every keyword under the page it points at", async function (assert) {
    await visit(KEYWORDS);

    assert
      .dom(".sitemap-autolink-admin__entry")
      .exists({ count: 2 }, "one card per destination, not per keyword");

    const first = ".sitemap-autolink-admin__entry[data-entry-id='11']";

    assert
      .dom(`${first} .sitemap-autolink-admin__entry-title`)
      .includesText("Widget Kit", "line 1 is the title")
      .includesText("product", "with its type as a pill");

    assert
      .dom(`${first} .sitemap-autolink-admin__entry-url`)
      .hasText("https://example.com/shop/widget-kit", "line 2 is the URL")
      .hasAttribute("href", "https://example.com/shop/widget-kit");

    assert
      .dom(`${first} .sitemap-autolink-admin__term`)
      .exists({ count: 4 }, "line 3 is every keyword for that page");

    assert
      .dom(`${first} .sitemap-autolink-admin__add-phrase`)
      .exists("line 4 adds another keyword");

    assert
      .dom(`${first} .sitemap-autolink-admin__toggle-entry`)
      .exists("and the page's own toggle sits in the header");

    assert
      .dom(
        ".sitemap-autolink-admin__entry[data-entry-id='12'] .sitemap-autolink-admin__entry-title"
      )
      .includesText(
        i18n("sitemap_autolink.admin.slug_title"),
        "a page titled from its slug is flagged"
      );
  });

  // "auto-active" is how a keyword got through review, not a promise
  // that it fires. A page filtered out of the sitemap keeps every one of
  // its auto-active keywords and links none of them.
  test("says plainly when a page cannot link, whatever its keywords say", async function (assert) {
    state.entries = {
      ...entriesPayload(),
      total: 1,
      linking_count: 0,
      entries: [{ ...entriesPayload().entries[0], removed_from_source: true }],
    };

    await visit(KEYWORDS);

    assert
      .dom(
        ".sitemap-autolink-admin__entry[data-entry-id='11'] .sitemap-autolink-admin__not-linking"
      )
      .hasText(
        i18n("sitemap_autolink.admin.page_removed_explainer"),
        "the card says the page is out, once, rather than per keyword"
      );

    assert.dom(".sitemap-autolink-admin__result-count").hasText(
      i18n("sitemap_autolink.admin.result_summary", {
        pages: 1,
        phrases: 4,
        linking: 0,
      }),
      "and the summary separates matching keywords from linking ones"
    );
  });

  test("can narrow to one of several sitemaps", async function (assert) {
    await visit(KEYWORDS);

    assert
      .dom(".sitemap-autolink-admin__sitemap-filter option")
      .exists({ count: 3 }, "every sitemap that produced entries, plus All");

    await fillIn(
      ".sitemap-autolink-admin__sitemap-filter",
      "https://example.com/sitemap-wiki.xml"
    );

    const request = lastRequest("entries");
    assert.strictEqual(
      request.queryParams.sitemap,
      "https://example.com/sitemap-wiki.xml"
    );
    assert.strictEqual(request.queryParams.page, "0");
  });

  test("hides the sitemap filter until a sync has recorded one", async function (assert) {
    state.entries = { ...entriesPayload(), sitemaps: [] };

    await visit(KEYWORDS);

    assert
      .dom(".sitemap-autolink-admin__sitemap-filter")
      .doesNotExist("no point offering a filter with one useless option");
  });

  test("can isolate pages that dropped out of the sitemap", async function (assert) {
    await visit(KEYWORDS);
    await fillIn(".sitemap-autolink-admin__page-state-filter", "removed");

    const request = lastRequest("entries");
    assert.strictEqual(request.queryParams.page_state, "removed");
    assert.strictEqual(
      request.queryParams.page,
      "0",
      "and starts from page one"
    );
  });

  test("marks a keyword another page also claims", async function (assert) {
    await visit(KEYWORDS);

    assert
      .dom(
        ".sitemap-autolink-admin__term[data-term-id='101'] .sitemap-autolink-admin__pill"
      )
      .hasText(
        i18n("sitemap_autolink.admin.duplicate"),
        "a contested keyword says so where it is read"
      );
    assert
      .dom(
        ".sitemap-autolink-admin__term[data-term-id='102'] .sitemap-autolink-admin__pill"
      )
      .doesNotExist("an uncontested one does not");
  });

  test("a keyword search finds the page that owns it", async function (assert) {
    await visit(KEYWORDS);

    await fillIn(
      ".sitemap-autolink-admin__search input[type='text']",
      "gasket"
    );
    await click(".sitemap-autolink-admin__search-btn");

    assert.strictEqual(lastRequest("entries").queryParams.q, "gasket");
    assert
      .dom(".sitemap-autolink-admin__entry")
      .exists({ count: 1 }, "only the owning page is listed");

    await click(
      ".sitemap-autolink-admin__state-filter[data-state='pending_review']"
    );

    const request = lastRequest("entries");
    assert.strictEqual(request.queryParams.state, "pending_review");
    assert.strictEqual(
      request.queryParams.page,
      "0",
      "filtering returns to the first page"
    );
  });

  test("the state filters carry their phrase counts", async function (assert) {
    await visit(KEYWORDS);

    assert
      .dom(
        ".sitemap-autolink-admin__state-filter[data-state='pending_review'] .sitemap-autolink-admin__filter-count"
      )
      .hasText("1");
    assert
      .dom(
        ".sitemap-autolink-admin__state-filter[data-state='all'] .sitemap-autolink-admin__filter-count"
      )
      .hasText("4", "All counts every keyword across the states");
  });

  test("pages paginate", async function (assert) {
    await visit(KEYWORDS);

    assert.dom(".sitemap-autolink-admin__page-indicator").hasText("1 / 2");

    await click(".sitemap-autolink-admin__next");
    assert.strictEqual(lastRequest("entries").queryParams.page, "1");
    assert.dom(".sitemap-autolink-admin__page-indicator").hasText("2 / 2");
  });

  test("a keyword can be approved, disabled and deleted in place", async function (assert) {
    await visit(KEYWORDS);

    const pending = ".sitemap-autolink-admin__term[data-term-id='103']";
    await click(`${pending} .sitemap-autolink-admin__approve-term`);

    assert.strictEqual(lastRequest("term").body.state, "approved");
    assert
      .dom(pending)
      .hasAttribute("data-state", "approved", "the chip reflects the change");

    await click(
      ".sitemap-autolink-admin__term[data-term-id='101'] .sitemap-autolink-admin__disable-term"
    );
    assert.strictEqual(lastRequest("term").body.state, "disabled");

    assert
      .dom(
        ".sitemap-autolink-admin__term[data-term-id='102'] .sitemap-autolink-admin__enable-term"
      )
      .exists("a disabled keyword offers a restore instead");

    assert
      .dom(
        ".sitemap-autolink-admin__term[data-term-id='101'] .sitemap-autolink-admin__delete-term"
      )
      .doesNotExist("a generated keyword cannot be deleted, only disabled");

    await click(
      ".sitemap-autolink-admin__term[data-term-id='104'] .sitemap-autolink-admin__delete-term"
    );
    await click(".dialog-footer .btn-primary");

    assert.true(lastRequest("delete-term").url.endsWith(`${BASE}/terms/104`));
    assert
      .dom(".sitemap-autolink-admin__term[data-term-id='104']")
      .doesNotExist("the manual alias is gone");
  });

  test("a keyword can be added to a page", async function (assert) {
    await visit(KEYWORDS);

    const entry = ".sitemap-autolink-admin__entry[data-entry-id='11']";
    await fillIn(
      `${entry} .sitemap-autolink-admin__add-phrase input`,
      "Foreman Widget"
    );
    await click(`${entry} .sitemap-autolink-admin__add-phrase button`);

    const created = lastRequest("create-term");
    assert.strictEqual(created.body.entry_id, "11");
    assert.strictEqual(created.body.phrase, "Foreman Widget");
    assert
      .dom(`${entry} .sitemap-autolink-admin__term`)
      .exists({ count: 5 }, "the new keyword joins the card");
  });

  test("a page can be disabled from its card", async function (assert) {
    await visit(KEYWORDS);

    const toggle =
      ".sitemap-autolink-admin__entry[data-entry-id='11'] .sitemap-autolink-admin__toggle-entry";
    await click(toggle);

    assert.strictEqual(lastRequest("entry").body.enabled, "false");
    assert.dom(toggle).hasText(i18n("sitemap_autolink.admin.enable"));
  });

  // 7,500 keywords cannot be reviewed 50 pages at a time.
  test("a whole filter can be approved at once", async function (assert) {
    await visit(KEYWORDS);
    await click(".sitemap-autolink-admin__approve-all");

    assert
      .dom(".dialog-body")
      .hasText(
        i18n("sitemap_autolink.admin.bulk_approved_confirm", { count: 4 }),
        "the bulk action names how many keywords it touches"
      );

    await click(".dialog-footer .btn-primary");

    const request = lastRequest("bulk");
    assert.strictEqual(request.body.state, "approved");
    assert.true(
      decodeURIComponent(request.raw).includes("filter["),
      "the current filter is submitted, not a list of ids"
    );
    assert
      .dom(".sitemap-autolink-admin__empty")
      .hasText(i18n("sitemap_autolink.admin.no_entries"));
  });
  // A page that dropped out of the sitemap keeps its keywords and links
  // nothing. That is right as a default and wrong as the only option:
  // a catalog re-pointed at different sitemaps fills with pages that
  // will never come back, so they have to be deletable.
  test("offers to delete the pages that are gone from the sitemap", async function (assert) {
    state.entries = { ...entriesPayload(), gone_pages: 2 };
    await visit(KEYWORDS);

    assert
      .dom(".sitemap-autolink-admin__purge-gone")
      .hasText(
        i18n("sitemap_autolink.admin.purge_gone", { count: 2 }),
        "the button names how many it would delete"
      );

    await click(".sitemap-autolink-admin__purge-gone");
    await click(".dialog-footer .btn-primary");

    const purge = lastRequest("purge");
    assert.ok(purge, "it deletes rather than disabling");
  });

  test("hides the delete button when nothing is gone", async function (assert) {
    await visit(KEYWORDS);
    assert.dom(".sitemap-autolink-admin__purge-gone").doesNotExist();
  });

  // The same URL is often listed in more than one sitemap, so a card
  // that named only one of them would be wrong.
  test("names every sitemap a page is listed in", async function (assert) {
    await visit(KEYWORDS);

    assert
      .dom(
        ".sitemap-autolink-admin__entry[data-entry-id='11'] .sitemap-autolink-admin__entry-sitemaps"
      )
      .includesText("sitemap-featured.xml")
      .includesText("sitemap-products.xml");
  });
});

acceptance("Sitemap Autolink | Admin | sitemaps", function (needs) {
  needs.user();
  needs.settings({ sitemap_autolink_enabled: true });
  needs.hooks.beforeEach(resetState);

  needs.pretender((server, helper) => {
    stubReads(server, helper);

    server.put(`${BASE}/sitemaps/:id`, (request) => {
      record("sitemap", request, helper);
      const id = parseInt(request.params.id, 10);
      const data = helper.parsePostData(request.requestBody);
      state.sitemaps = {
        ...state.sitemaps,
        pending: 0,
        sitemaps: state.sitemaps.sitemaps.map((s) =>
          s.id === id ? { ...s, status: data.status } : s
        ),
      };
      return helper.response({ success: "OK", orphaned: 0, purged: 0 });
    });

    server.post(`${BASE}/sitemaps/discover`, (request) => {
      record("discover", request, helper);
      return helper.response({ success: "OK", errors: [], notes: [] });
    });

    server.delete(`${BASE}/entries/purge`, (request) => {
      record("purge", request, helper);
      return helper.response({ success: "OK", purged: 2 });
    });
  });

  // Naming an index in a setting says nothing about which of the
  // sitemaps inside it belong in a link catalog. This page is where
  // that is decided, so it has to show the children AND their sizes.
  test("shows an index's children with their sizes", async function (assert) {
    await visit(SITEMAPS);

    assert
      .dom(".sitemap-autolink-admin__sitemap")
      .exists({ count: 3 }, "the index and both of its children");

    assert
      .dom(".sitemap-autolink-admin__sitemap[data-sitemap-id='3']")
      .hasClass("--child", "children are indented under their index")
      .hasAttribute("data-status", "pending");

    assert
      .dom(
        ".sitemap-autolink-admin__sitemap[data-sitemap-id='3'] .sitemap-autolink-admin__sitemap-count"
      )
      .includesText(
        "41000+",
        "a truncated count reads as a floor, not a total"
      );

    assert
      .dom(".sitemap-autolink-admin__warning")
      .includesText(
        i18n("sitemap_autolink.admin.pending_sitemaps", { count: 1 }),
        "and says plainly that nothing from it was imported"
      );
  });

  // An index imports nothing itself, so its row has to account for the
  // decisions it created rather than leave them to be counted by eye.
  test("an index row accounts for the decisions it created", async function (assert) {
    await visit(SITEMAPS);

    assert
      .dom(".sitemap-autolink-admin__sitemap[data-sitemap-id='1']")
      .includesText(
        i18n("sitemap_autolink.admin.index_children", {
          count: 2,
          imported: 1,
          pending: 1,
          ignored: 0,
        })
      );

    assert
      .dom(".sitemap-autolink-admin__sitemap[data-sitemap-id='3']")
      .includesText(
        i18n("sitemap_autolink.admin.listed_by", {
          url: "https://example.com/sitemap.xml",
        }),
        "and a child names the index that listed it, not just its indent"
      );

    assert
      .dom(".sitemap-autolink-admin__legend")
      .exists("the three states are explained where the decisions are made");
  });

  test("imports a child sitemap only when told to", async function (assert) {
    await visit(SITEMAPS);

    const pending = ".sitemap-autolink-admin__sitemap[data-sitemap-id='3']";
    assert.dom(`${pending} .sitemap-autolink-admin__import`).exists();

    await click(`${pending} .sitemap-autolink-admin__import`);

    assert.strictEqual(
      lastRequest("sitemap").body.status,
      "enabled",
      "approving it is what starts the import"
    );
    assert
      .dom(`${pending}`)
      .hasAttribute("data-status", "enabled", "and the row reflects it");
  });

  test("declining a sitemap never fetches it again", async function (assert) {
    await visit(SITEMAPS);

    await click(
      ".sitemap-autolink-admin__sitemap[data-sitemap-id='3'] .sitemap-autolink-admin__ignore"
    );

    assert.strictEqual(lastRequest("sitemap").body.status, "ignored");
  });

  // Two ways to stop, because "keep the pages" and "delete the pages"
  // are different answers and one confirm cannot ask for both.
  test("stopping an import can keep or delete the pages", async function (assert) {
    await visit(SITEMAPS);

    const importing = ".sitemap-autolink-admin__sitemap[data-sitemap-id='2']";
    assert.dom(`${importing} .sitemap-autolink-admin__stop-importing`).exists();
    assert.dom(`${importing} .sitemap-autolink-admin__stop-purge`).exists();

    await click(`${importing} .sitemap-autolink-admin__stop-purge`);
    await click(".dialog-footer .btn-primary");

    const request = lastRequest("sitemap");
    assert.strictEqual(request.body.status, "ignored");
    assert.strictEqual(
      request.body.purge,
      "true",
      "the destructive one asks for the pages to be deleted"
    );
  });

  // Dead pages accumulate per sitemap, and the row that reports the
  // count is the natural place to act on it.
  test("purges one sitemap's gone pages from its own row", async function (assert) {
    await visit(SITEMAPS);

    const importing = ".sitemap-autolink-admin__sitemap[data-sitemap-id='2']";
    await click(`${importing} .sitemap-autolink-admin__purge-sitemap-gone`);
    await click(".dialog-footer .btn-primary");

    // Either transport is fine (jQuery puts DELETE data in the body,
    // but the URL is checked too); what matters is the scoping.
    const purge = lastRequest("purge");
    assert.true(
      decodeURIComponent(`${purge.url} ${purge.raw || ""}`).includes(
        "filter[sitemap]=https://example.com/sitemap-products.xml"
      ),
      "scoped to that sitemap, not the whole catalog"
    );
  });

  test("offers no delete on a sitemap with nothing gone", async function (assert) {
    await visit(SITEMAPS);

    assert
      .dom(
        ".sitemap-autolink-admin__sitemap[data-sitemap-id='3'] .sitemap-autolink-admin__purge-sitemap-gone"
      )
      .doesNotExist();
  });

  test("reads the configured sitemaps on demand", async function (assert) {
    await visit(SITEMAPS);

    await click(".sitemap-autolink-admin__discover");

    assert.ok(lastRequest("discover"), "discovery is explicit, not a sync");
    assert
      .dom(".sitemap-autolink-admin__notice")
      .hasText(i18n("sitemap_autolink.admin.discover_done"));
  });
});

acceptance("Sitemap Autolink | Admin | conflicts", function (needs) {
  needs.user();
  needs.settings({ sitemap_autolink_enabled: true });
  needs.hooks.beforeEach(resetState);
  needs.pretender((server, helper) => {
    stubReads(server, helper);
    server.post(`${BASE}/collisions/resolve`, (request) => {
      record("resolve", request, helper);
      return helper.response({ success: "OK", disabled: 1 });
    });
  });

  // Scoping detection to active entries made this report disagree with
  // the catalog on screen: pages visibly claiming one keyword came back
  // as "no conflicts".
  test("reports every page claiming a keyword, live or not", async function (assert) {
    await visit(CONFLICTS);

    assert
      .dom(".sitemap-autolink-admin__collision")
      .exists({ count: 1 }, "the contested keyword is reported");

    assert
      .dom(".sitemap-autolink-admin__candidate")
      .exists({ count: 3 }, "every page claiming it is listed");

    assert
      .dom(".sitemap-autolink-admin__candidate.is-winner")
      .includesText(
        i18n("sitemap_autolink.admin.collision_winner"),
        "the one that actually links is marked"
      );

    assert
      .dom(".sitemap-autolink-admin__candidate.is-inactive")
      .exists(
        { count: 1 },
        "and a claimant that cannot link is shown, not dropped"
      );

    // The reason names itself. It is also the one check that the reason
    // strings the server sends still have locale keys to land on, since
    // the template looks them up by concatenation.
    assert
      .dom(".sitemap-autolink-admin__candidate.is-inactive")
      .includesText(i18n("sitemap_autolink.admin.reason_page_gone"));

    // Offering it here was a footgun: the page cannot link, so handing
    // it the keyword disabled the two that could and took the phrase
    // offline altogether.
    assert
      .dom(
        ".sitemap-autolink-admin__candidate.is-inactive .sitemap-autolink-admin__make-winner"
      )
      .doesNotExist("no Give it this page on a claimant that cannot link");

    assert
      .dom(".sitemap-autolink-admin__make-winner")
      .exists({ count: 1 }, "only the live rival that is not already winning");
  });

  // Settled questions are left out by default now, so the checkbox adds
  // them back rather than taking the noise away.
  test("can ask for the settled ones as well", async function (assert) {
    await visit(CONFLICTS);

    assert.strictEqual(
      lastRequest("collisions").queryParams.include_inactive,
      undefined,
      "the default report is only what is still undecided"
    );

    await click(".sitemap-autolink-admin__competing-filter input");

    assert.strictEqual(
      lastRequest("collisions").queryParams.include_inactive,
      "true"
    );
    assert.strictEqual(
      lastRequest("overlaps").queryParams.include_inactive,
      "true",
      "both reports, not just the one above"
    );
  });

  test("says how many settled ones are being left out", async function (assert) {
    await visit(CONFLICTS);

    assert
      .dom(".sitemap-autolink-admin__collisions")
      .includesText(
        i18n("sitemap_autolink.admin.collisions_settled", { count: 4 })
      );

    assert
      .dom(".sitemap-autolink-admin__overlaps")
      .includesText(
        i18n("sitemap_autolink.admin.overlaps_same_destination", { count: 6 }),
        "and how many contained keywords lead to the same page anyway"
      );
  });

  test("hands a contested keyword to one page", async function (assert) {
    await visit(CONFLICTS);
    await click(
      ".sitemap-autolink-admin__candidate[data-entry-id='2'] .sitemap-autolink-admin__make-winner"
    );
    await click(".dialog-footer .btn-primary");

    const request = lastRequest("resolve");
    assert.strictEqual(request.body.phrase, "widget kit");
    assert.strictEqual(request.body.entry_id, "2");
    assert
      .dom(".sitemap-autolink-admin__notice")
      .hasText(i18n("sitemap_autolink.admin.make_winner_done", { count: 1 }));
  });

  // A long title can contain several other pages' keywords; each of
  // them has to be reported against it, whether or not it links today.
  test("lists every keyword buried inside a longer one", async function (assert) {
    await visit(CONFLICTS);

    assert
      .dom(".sitemap-autolink-admin__overlap")
      .exists({ count: 2 }, "both swallowed keywords are reported");

    assert
      .dom(
        ".sitemap-autolink-admin__overlap[data-phrase='widget kit'] .sitemap-autolink-admin__covering"
      )
      .includesText(
        "acme widget kit gasket set",
        "naming the longer keyword that wins the span"
      );

    assert
      .dom(".sitemap-autolink-admin__overlap[data-phrase='gasket set']")
      .includesText(
        i18n("sitemap_autolink.admin.not_linking"),
        "a swallowed keyword that is not live is still reported, and marked"
      );

    assert
      .dom(
        ".sitemap-autolink-admin__overlap[data-phrase='widget kit'] .sitemap-autolink-admin__owner a"
      )
      .exists("each keyword names the page that owns it");
  });
});

acceptance("Sitemap Autolink | Admin | overview and logs", function (needs) {
  needs.user();
  needs.settings({ sitemap_autolink_enabled: true });
  needs.hooks.beforeEach(resetState);

  needs.pretender((server, helper) => {
    stubReads(server, helper);
    server.post(`${BASE}/sync`, (request) => {
      record("sync", request, helper);
      return helper.response({ success: "OK" });
    });
    server.post(`${BASE}/sync/cancel`, (request) => {
      record("cancel", request, helper);
      return helper.response({ success: "OK" });
    });
    server.post(`${BASE}/preview`, (request) => {
      record("preview", request, helper);
      return helper.response(previewPayload());
    });
    server.post(`${BASE}/rebake`, (request) => {
      record("rebake", request, helper);
      return helper.response({ success: "OK" });
    });
  });

  test("summarizes the catalog", async function (assert) {
    await visit(OVERVIEW);

    assert
      .dom(".sitemap-autolink-admin__stat-group")
      .exists({ count: 4 }, "pages, keywords, linking and sitemaps");

    assert
      .dom('.sitemap-autolink-admin__stat-group[data-group="pages"]')
      .includesText(i18n("sitemap_autolink.admin.stat_pages_live"));

    assert
      .dom('.sitemap-autolink-admin__stat[data-tone="warn"]')
      .exists(
        { count: 3 },
        "pages gone, keywords awaiting review and contested keywords ask for a decision"
      );

    assert
      .dom(".sitemap-autolink-admin__stat-breakdown")
      .includesText("product", "with the per-type breakdown");

    assert
      .dom(".sitemap-autolink-admin__status .sitemap-autolink-admin__warning")
      .doesNotExist("a healthy catalog raises no warnings");
  });

  test("Sync now enqueues a run, then offers to cancel it", async function (assert) {
    await visit(OVERVIEW);
    await click(".sitemap-autolink-admin__sync");

    assert.ok(lastRequest("sync"), "a sync was requested");
    assert
      .dom(".sitemap-autolink-admin__notice")
      .hasText(i18n("sitemap_autolink.admin.sync_started"));

    await click(".sitemap-autolink-admin__cancel");

    assert.ok(lastRequest("cancel"), "the running sync can be cancelled");
    assert
      .dom(".sitemap-autolink-admin__notice")
      .hasText(i18n("sitemap_autolink.admin.cancel_requested"));
  });

  test("Preview renders what would be ingested", async function (assert) {
    await visit(OVERVIEW);

    assert
      .dom(".sitemap-autolink-admin__preview")
      .doesNotExist("no preview before one is requested");

    await click(".sitemap-autolink-admin__preview-btn");

    assert.strictEqual(lastRequest("preview").body.limit, "5");
    assert
      .dom(".sitemap-autolink-admin__preview .sitemap-autolink-admin__entry")
      .exists({ count: 1 }, "the sampled page is shown as a card too");
    assert
      .dom(".sitemap-autolink-admin__preview .sitemap-autolink-admin__term")
      .exists({ count: 2 }, "with the keywords it would generate");
  });

  test("Rebake asks for confirmation before enqueuing the wave", async function (assert) {
    await visit(OVERVIEW);
    await click(".sitemap-autolink-admin__rebake");

    assert
      .dom(".dialog-body")
      .hasText(i18n("sitemap_autolink.admin.rebake_all_confirm"));

    await click(".dialog-footer .btn-primary");

    assert.strictEqual(lastRequest("rebake").body.all, "true");
    assert
      .dom(".sitemap-autolink-admin__notice")
      .hasText(i18n("sitemap_autolink.admin.rebake_all_started"));
  });

  test("the logs page lists every run with its errors", async function (assert) {
    await visit(LOGS);

    assert
      .dom(".sitemap-autolink-admin__runs tbody tr:first-child td:nth-child(3)")
      .hasText(i18n("sitemap_autolink.admin.run_ok"));
    assert
      .dom(".sitemap-autolink-admin__errors")
      .hasText("failed to fetch sitemap https://example.com/sitemap.xml");
  });
});

acceptance("Sitemap Autolink | Admin | misconfiguration", function (needs) {
  needs.user();
  needs.settings({ sitemap_autolink_enabled: false });

  needs.hooks.beforeEach(function () {
    resetState();
    // Plugin off, no sitemaps configured, and every entry filtered out
    // by sitemap_autolink_enabled_types.
    state.status = statusPayload({
      enabled: false,
      sources_configured: false,
      active_rules: 0,
      entry_types: ["product"],
      enabled_types_setting: "wiki",
    });
  });

  needs.pretender((server, helper) => stubReads(server, helper));

  test("diagnoses why nothing is being linked", async function (assert) {
    await visit(OVERVIEW);

    const warning = (name) =>
      `.sitemap-autolink-admin__status [data-warning="${name}"]`;
    assert
      .dom(warning("plugin-disabled"))
      .hasText(i18n("sitemap_autolink.admin.plugin_disabled"));
    assert
      .dom(warning("no-sources"))
      .hasText(i18n("sitemap_autolink.admin.no_sources"));
    assert.dom(warning("no-rules")).hasText(
      i18n("sitemap_autolink.admin.no_rules_hint", {
        entry_types: "product",
        allowed: "wiki",
      }),
      "explains that enabled_types is filtering every entry out"
    );
  });
});

acceptance("Sitemap Autolink | Admin | unavailable data", function (needs) {
  needs.user();
  needs.settings({ sitemap_autolink_enabled: true });
  needs.hooks.beforeEach(resetState);

  // A failed request must not be drawn as an empty catalog: "you have no
  // keywords" and "we could not load your keywords" are different facts.
  needs.pretender((server, helper) => {
    server.get(`${BASE}.json`, () => helper.response(pluginPayload()));
    server.get(`${BASE}/status`, () => helper.response(500, {}));
    server.get(`${BASE}/runs`, () => helper.response(500, {}));
    server.get(`${BASE}/entries`, () => helper.response(500, {}));
    server.get(`${BASE}/collisions`, () => helper.response(500, {}));
    server.get(`${BASE}/overlaps`, () => helper.response(500, {}));
  });

  test("says the load failed instead of rendering an empty catalog", async function (assert) {
    await visit(KEYWORDS);

    assert
      .dom(".sitemap-autolink-admin__warning")
      .hasText(i18n("sitemap_autolink.admin.load_failed"));
    assert
      .dom(".sitemap-autolink-admin__empty")
      .doesNotExist("and does not claim the catalog is empty");
  });

  test("the conflicts page does the same", async function (assert) {
    await visit(CONFLICTS);

    assert
      .dom(".sitemap-autolink-admin__warning")
      .hasText(i18n("sitemap_autolink.admin.load_failed"));
    assert
      .dom(".sitemap-autolink-admin__empty")
      .doesNotExist("a failed conflict report never reads as 'no conflicts'");
  });
});

acceptance("Sitemap Autolink | Admin | plugin disabled", function (needs) {
  needs.user();
  needs.settings({ sitemap_autolink_enabled: false });
  needs.hooks.beforeEach(resetState);

  // With the plugin off, `requires_plugin` answers 404 for every one of
  // its endpoints — the exact state a first-time admin lands in.
  needs.pretender((server, helper) => {
    server.get(`${BASE}.json`, () => helper.response(pluginPayload()));
    ["status", "runs", "entries", "collisions", "overlaps"].forEach((path) =>
      server.get(`${BASE}/${path}`, () => helper.response(404, {}))
    );
  });

  test("names the cause instead of blaming the error log", async function (assert) {
    await visit(OVERVIEW);
    assert
      .dom(".sitemap-autolink-admin__status .sitemap-autolink-admin__warning")
      .hasText(i18n("sitemap_autolink.admin.plugin_disabled"));

    await visit(KEYWORDS);
    assert
      .dom(".sitemap-autolink-admin__warning")
      .hasText(i18n("sitemap_autolink.admin.plugin_disabled"));
  });
});
