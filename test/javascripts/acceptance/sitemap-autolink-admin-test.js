import { click, currentURL, fillIn, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";
import { i18n } from "discourse-i18n";

const PLUGIN_ID = "discourse-sitemap-autolink";
const BASE = `/admin/plugins/${PLUGIN_ID}`;
const OVERVIEW = `${BASE}/overview`;
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
    enabled_types_setting: "product|wiki",
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
    state_counts: {
      auto_active: 1,
      pending_review: 1,
      approved: 1,
      disabled: 1,
    },
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
        source: "https://example.com/sitemap.xml",
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
        source: "https://example.com/sitemap.xml",
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
    collisions: [
      {
        phrase: "proton pack",
        winner: "https://example.com/shop/proton-pack",
        linking_candidates: 2,
        candidates: [
          {
            url: "https://example.com/shop/proton-pack",
            title: "Proton Pack",
            type: "product",
            state: "auto_active",
            linking: true,
            winner: true,
          },
          {
            url: "https://example.com/wiki/proton-pack",
            title: "Real Ghostbusters: Proton Pack",
            type: "wiki",
            state: "auto_active",
            linking: true,
            winner: false,
          },
          {
            url: "https://example.com/old/proton-pack",
            title: "Proton Pack",
            type: "wiki",
            state: "auto_active",
            linking: false,
            winner: false,
          },
        ],
      },
    ],
  };
}

function overlapsPayload() {
  return {
    total: 1,
    page: 0,
    per_page: 50,
    pages: 1,
    truncated: false,
    overlaps: [
      {
        phrase: "widget kit",
        url: "https://example.com/shop/widget-kit",
        type: "product",
        covered_by: [
          {
            phrase: "deluxe widget kit",
            url: "https://example.com/shop/deluxe-widget-kit",
            type: "product",
          },
        ],
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
  server.get(`${BASE}/overlaps`, () => helper.response(state.overlaps));

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
    assert
      .dom(nav)
      .exists({ count: 4 }, "the plugin nav lists every page, not one Catalog");

    ["overview", "keywords", "conflicts", "logs"].forEach((page) => {
      assert
        .dom(`${nav}[href="${BASE}/${page}"]`)
        .hasText(i18n(`sitemap_autolink.admin.nav.${page}`));
    });
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

    assert.dom(".sitemap-autolink-admin__pagination span").hasText("1 / 2");

    await click(".sitemap-autolink-admin__next");
    assert.strictEqual(lastRequest("entries").queryParams.page, "1");
    assert.dom(".sitemap-autolink-admin__pagination span").hasText("2 / 2");
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
});

acceptance("Sitemap Autolink | Admin | conflicts", function (needs) {
  needs.user();
  needs.settings({ sitemap_autolink_enabled: true });
  needs.hooks.beforeEach(resetState);
  needs.pretender((server, helper) => stubReads(server, helper));

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
  });

  test("can narrow to the contests that change what links", async function (assert) {
    await visit(CONFLICTS);
    await click(".sitemap-autolink-admin__competing-filter input");

    assert.strictEqual(
      lastRequest("collisions").queryParams.only_competing,
      "true"
    );
  });

  test("lists keywords buried inside longer ones", async function (assert) {
    await visit(CONFLICTS);

    assert
      .dom(".sitemap-autolink-admin__overlap")
      .exists({ count: 1 }, "overlaps get their own report");
    assert
      .dom(".sitemap-autolink-admin__covering")
      .includesText(
        "deluxe widget kit",
        "naming the longer keyword that wins the span"
      );
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

    assert.dom(".sitemap-autolink-admin__status p").hasText(
      i18n("sitemap_autolink.admin.status_summary", {
        rules: 3,
        entries: 2,
        pending: 2,
      })
    );
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

    const warnings = ".sitemap-autolink-admin__status p";
    assert
      .dom(`${warnings}:nth-of-type(2)`)
      .hasText(i18n("sitemap_autolink.admin.plugin_disabled"));
    assert
      .dom(`${warnings}:nth-of-type(3)`)
      .hasText(i18n("sitemap_autolink.admin.no_sources"));
    assert.dom(`${warnings}:nth-of-type(4)`).hasText(
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
