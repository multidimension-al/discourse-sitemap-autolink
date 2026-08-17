import { click, fillIn, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";
import { i18n } from "discourse-i18n";

const PLUGIN_ID = "discourse-sitemap-autolink";
const BASE = `/admin/plugins/${PLUGIN_ID}`;
const CATALOG_URL = `${BASE}/catalog`;

function pluginPayload() {
  return {
    id: PLUGIN_ID,
    name: PLUGIN_ID,
    humanized_name: "Sitemap Autolink",
    about: "Automatically links the first mention of your site's pages.",
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
          term(101, "Widget Kit", "approved"),
          term(102, "widget kits", "disabled"),
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
        terms: [term(103, "gasket set", "approved", { entry_id: 12 })],
      },
    ],
  };
}

function pendingPayload() {
  return {
    total: 2,
    pending: [
      term(201, "Flux", "pending_review", {
        entry_id: 12,
        review_reason: "phrase shorter than 5 characters",
        entry_url: "https://example.com/wiki/flux",
        entry_title: "Flux",
        entry_type: "wiki",
      }),
      term(202, "Kits", "pending_review", {
        entry_id: 11,
        review_reason: "phrase is a single common word",
        entry_url: "https://example.com/shop/widget-kit",
        entry_title: "Widget Kit",
        entry_type: "product",
      }),
    ],
  };
}

function collisionsPayload() {
  return [
    {
      phrase: "flux",
      winner: "https://example.com/shop/flux",
      candidates: [
        { url: "https://example.com/shop/flux", type: "product" },
        { url: "https://example.com/wiki/flux", type: "wiki" },
      ],
    },
  ];
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

// Server state and the requests the page made, rebuilt before each test
// so one test's clicks can never leak into the next.
let state;
let requests;

function record(name, request, helper) {
  requests.push({
    name,
    url: request.url,
    queryParams: request.queryParams,
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
    pending: pendingPayload(),
    collisions: collisionsPayload(),
    entries: entriesPayload(),
  };
  requests = [];
}

// The catalog page issues the same five reads on entry and after every
// refresh, so every module needs them stubbed.
function stubCatalogEndpoints(server, helper, { status } = {}) {
  server.get(`${BASE}.json`, () => helper.response(pluginPayload()));
  server.get(`${BASE}/status`, () =>
    status ? status() : helper.response(state.status)
  );
  server.get(`${BASE}/runs`, () => helper.response({ runs: state.runs }));
  server.get(`${BASE}/pending`, () => helper.response(state.pending));
  server.get(`${BASE}/collisions`, () =>
    helper.response({ collisions: state.collisions })
  );
  server.get(`${BASE}/entries`, (request) => {
    record("entries", request, helper);
    const query = request.queryParams.q;
    const payload = state.entries;
    if (!query) {
      return helper.response(payload);
    }
    const matching = payload.entries.filter((entry) =>
      `${entry.title} ${entry.url}`.toLowerCase().includes(query.toLowerCase())
    );
    return helper.response({
      ...payload,
      total: matching.length,
      pages: 1,
      entries: matching,
    });
  });
}

acceptance("Sitemap Autolink | Admin catalog", function (needs) {
  needs.user();
  needs.settings({ sitemap_autolink_enabled: true });

  needs.hooks.beforeEach(resetState);

  needs.pretender((server, helper) => {
    stubCatalogEndpoints(server, helper);

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

    server.put(`${BASE}/terms/bulk`, (request) => {
      record("bulk", request, helper);
      state.pending = { total: 0, pending: [] };
      state.status = statusPayload({ pending_terms: 0 });
      return helper.response({ success: "OK", updated: 2 });
    });

    server.put(`${BASE}/terms/:id`, (request) => {
      record("term", request, helper);
      const id = parseInt(request.params.id, 10);
      const existing = [...state.pending.pending, ...allEntryTerms()].find(
        (t) => t.id === id
      );
      return helper.response({
        ...existing,
        state: helper.parsePostData(request.requestBody).state,
      });
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

  function allEntryTerms() {
    return state.entries.entries.flatMap((entry) => entry.terms);
  }

  test("the plugin registers a catalog tab on its admin page", async function (assert) {
    await visit(CATALOG_URL);

    assert
      .dom(`.admin-plugin-config-page__top-nav-item a[href="${CATALOG_URL}"]`)
      .hasText(
        i18n("sitemap_autolink.admin.catalog_title"),
        "the catalog tab is linked from the plugin nav"
      );

    assert
      .dom(".sitemap-autolink-admin")
      .exists("the catalog page is rendered");
  });

  test("shows catalog status, history, review queue, entries and collisions", async function (assert) {
    await visit(CATALOG_URL);

    assert.dom(".sitemap-autolink-admin__status p").hasText(
      i18n("sitemap_autolink.admin.status_summary", {
        rules: 3,
        entries: 2,
        pending: 2,
      }),
      "summarizes the compiled ruleset"
    );

    assert
      .dom(".sitemap-autolink-admin__status .sitemap-autolink-admin__warning")
      .doesNotExist("a healthy catalog raises no warnings");

    assert
      .dom(".sitemap-autolink-admin__runs tbody tr:first-child td:nth-child(3)")
      .hasText(i18n("sitemap_autolink.admin.run_ok"), "the last run succeeded");

    assert
      .dom(".sitemap-autolink-admin__errors")
      .hasText(
        "failed to fetch sitemap https://example.com/sitemap.xml",
        "a failed run can be expanded for its errors"
      );

    assert
      .dom(".sitemap-autolink-admin__pending-row")
      .exists({ count: 2 }, "both pending phrases are listed for review");

    assert
      .dom(
        ".sitemap-autolink-admin__pending-row[data-term-id='201'] td:nth-child(2)"
      )
      .hasText(
        "phrase shorter than 5 characters",
        "each pending phrase explains why it needs review"
      );

    assert
      .dom(".sitemap-autolink-admin__entry")
      .exists({ count: 2 }, "the catalog entries are listed");

    assert
      .dom(".sitemap-autolink-admin__entry[data-entry-id='12'] td:first-child")
      .includesText(
        i18n("sitemap_autolink.admin.slug_title"),
        "an entry titled from its slug is flagged"
      );

    assert
      .dom(
        ".sitemap-autolink-admin__entry[data-entry-id='11'] .sitemap-autolink-admin__term"
      )
      .exists({ count: 2 }, "an entry lists all of its phrases");

    assert
      .dom(".sitemap-autolink-admin__collisions summary")
      .hasText(
        `${i18n("sitemap_autolink.admin.collisions_title")} (1)`,
        "collisions are counted"
      );

    assert
      .dom(".sitemap-autolink-admin__candidate")
      .exists({ count: 2 }, "both destinations claiming a phrase are shown");
  });

  test("Sync now enqueues a run, then offers to cancel it", async function (assert) {
    await visit(CATALOG_URL);
    await click(".sitemap-autolink-admin__sync");

    assert.ok(lastRequest("sync"), "a sync was requested");
    assert
      .dom(".sitemap-autolink-admin__notice")
      .hasText(
        i18n("sitemap_autolink.admin.sync_started"),
        "the admin is told the run started"
      );

    await click(".sitemap-autolink-admin__cancel");

    assert.ok(lastRequest("cancel"), "the running sync can be cancelled");
    assert
      .dom(".sitemap-autolink-admin__notice")
      .hasText(i18n("sitemap_autolink.admin.cancel_requested"));
  });

  test("Preview runs a dry run and renders what would be ingested", async function (assert) {
    await visit(CATALOG_URL);

    assert
      .dom(".sitemap-autolink-admin__preview")
      .doesNotExist("no preview is shown before one is requested");

    await click(".sitemap-autolink-admin__preview-btn");

    assert.strictEqual(
      lastRequest("preview").body.limit,
      "5",
      "samples a handful of URLs per source"
    );

    assert
      .dom(".sitemap-autolink-admin__preview h4")
      .hasText(
        "https://example.com/sitemap.xml (product)",
        "each source is titled with its content type"
      );

    assert
      .dom(".sitemap-autolink-admin__preview tbody tr")
      .exists({ count: 1 }, "the sampled page is listed");

    assert
      .dom(".sitemap-autolink-admin__preview tbody tr td:nth-child(3)")
      .includesText(
        "pending_review",
        "phrases show the state they would be created in"
      );
  });

  test("Rebake asks for confirmation before enqueuing the wave", async function (assert) {
    await visit(CATALOG_URL);
    await click(".sitemap-autolink-admin__rebake");

    assert
      .dom(".dialog-body")
      .hasText(
        i18n("sitemap_autolink.admin.rebake_all_confirm"),
        "a rebake of every matching post is confirmed first"
      );

    await click(".dialog-footer .btn-primary");

    assert.strictEqual(
      lastRequest("rebake").body.all,
      "true",
      "rebakes every post that may contain a phrase"
    );
    assert
      .dom(".sitemap-autolink-admin__notice")
      .hasText(i18n("sitemap_autolink.admin.rebake_all_started"));
  });

  test("approving a pending phrase removes it from the queue", async function (assert) {
    await visit(CATALOG_URL);
    await click(
      ".sitemap-autolink-admin__pending-row[data-term-id='201'] .sitemap-autolink-admin__approve"
    );

    const request = lastRequest("term");
    assert.true(
      request.url.endsWith(`${BASE}/terms/201`),
      "the reviewed phrase is updated"
    );
    assert.strictEqual(request.body.state, "approved");

    assert
      .dom(".sitemap-autolink-admin__pending-row")
      .exists({ count: 1 }, "the approved phrase leaves the queue");
    assert
      .dom(".sitemap-autolink-admin__pending h3")
      .hasText(
        `${i18n("sitemap_autolink.admin.pending_title")} (1)`,
        "the queue count drops"
      );
  });

  test("the review queue can be cleared in bulk", async function (assert) {
    await visit(CATALOG_URL);
    await click(".sitemap-autolink-admin__approve-all");

    assert
      .dom(".dialog-body")
      .hasText(
        i18n("sitemap_autolink.admin.bulk_approved_confirm", { count: 2 }),
        "the bulk action names how many phrases it touches"
      );

    await click(".dialog-footer .btn-primary");

    const request = lastRequest("bulk");
    assert.deepEqual(
      request.body["ids[]"],
      ["201", "202"],
      "every listed phrase is submitted"
    );
    assert.strictEqual(request.body.state, "approved");

    assert
      .dom(".sitemap-autolink-admin__pending p")
      .hasText(
        i18n("sitemap_autolink.admin.no_pending"),
        "the page reloads itself and the queue is empty"
      );
  });

  test("entries can be searched and filtered", async function (assert) {
    await visit(CATALOG_URL);

    await fillIn(
      ".sitemap-autolink-admin__search input[type='text']",
      "gasket"
    );
    await click(".sitemap-autolink-admin__search-btn");

    assert.strictEqual(lastRequest("entries").queryParams.q, "gasket");
    assert
      .dom(".sitemap-autolink-admin__entry")
      .exists({ count: 1 }, "only matching entries are listed");

    await fillIn(".sitemap-autolink-admin__type-filter", "wiki");
    assert.strictEqual(
      lastRequest("entries").queryParams.type,
      "wiki",
      "the type filter is sent to the server"
    );

    await click(".sitemap-autolink-admin__pending-filter input");
    assert.strictEqual(
      lastRequest("entries").queryParams.pending,
      "true",
      "the review filter is sent to the server"
    );
    assert.strictEqual(
      lastRequest("entries").queryParams.page,
      "0",
      "filtering returns to the first page"
    );
  });

  test("entries paginate", async function (assert) {
    await visit(CATALOG_URL);

    assert.dom(".sitemap-autolink-admin__pagination span").hasText("1 / 2");

    await click(".sitemap-autolink-admin__next");
    assert.strictEqual(lastRequest("entries").queryParams.page, "1");
    assert.dom(".sitemap-autolink-admin__pagination span").hasText("2 / 2");

    await click(".sitemap-autolink-admin__prev");
    assert.strictEqual(lastRequest("entries").queryParams.page, "0");
    assert.dom(".sitemap-autolink-admin__pagination span").hasText("1 / 2");
  });

  test("an entry can be disabled without leaving the page", async function (assert) {
    await visit(CATALOG_URL);

    const toggle =
      ".sitemap-autolink-admin__entry[data-entry-id='11'] .sitemap-autolink-admin__toggle-entry";
    assert
      .dom(toggle)
      .hasText(i18n("sitemap_autolink.admin.disable"), "the entry is active");

    await click(toggle);

    const request = lastRequest("entry");
    assert.true(request.url.endsWith(`${BASE}/entries/11`));
    assert.strictEqual(request.body.enabled, "false");
    assert
      .dom(toggle)
      .hasText(
        i18n("sitemap_autolink.admin.enable"),
        "the row reflects the new state"
      );
  });

  test("a phrase can be disabled and a manual alias added", async function (assert) {
    await visit(CATALOG_URL);

    const entry = ".sitemap-autolink-admin__entry[data-entry-id='11']";

    await click(`${entry} .sitemap-autolink-admin__disable-term`);

    const update = lastRequest("term");
    assert.true(update.url.endsWith(`${BASE}/terms/101`));
    assert.strictEqual(update.body.state, "disabled");
    assert
      .dom(`${entry} .sitemap-autolink-admin__enable-term`)
      .exists({ count: 2 }, "both phrases can now be re-enabled");

    await fillIn(
      `${entry} .sitemap-autolink-admin__add-phrase input`,
      "Deluxe Widget Kit"
    );
    await click(`${entry} .sitemap-autolink-admin__add-phrase button`);

    const created = lastRequest("create-term");
    assert.strictEqual(created.body.entry_id, "11");
    assert.strictEqual(created.body.phrase, "Deluxe Widget Kit");

    assert
      .dom(`${entry} .sitemap-autolink-admin__term`)
      .exists({ count: 3 }, "the alias joins the entry's phrases");
    assert
      .dom(`${entry} .sitemap-autolink-admin__term:last-of-type`)
      .includesText("Deluxe Widget Kit");
    assert
      .dom(`${entry} .sitemap-autolink-admin__add-phrase input`)
      .hasNoValue("the input is cleared for the next alias");
  });
});

acceptance(
  "Sitemap Autolink | Admin catalog | misconfiguration",
  function (needs) {
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

    needs.pretender((server, helper) => stubCatalogEndpoints(server, helper));

    test("diagnoses why nothing is being linked", async function (assert) {
      await visit(CATALOG_URL);

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
  }
);

acceptance(
  "Sitemap Autolink | Admin catalog | unavailable data",
  function (needs) {
    needs.user();
    needs.settings({ sitemap_autolink_enabled: true });

    needs.hooks.beforeEach(resetState);

    needs.pretender((server, helper) =>
      stubCatalogEndpoints(server, helper, {
        status: () => helper.response(500, {}),
      })
    );

    test("says so instead of rendering an empty status", async function (assert) {
      await visit(CATALOG_URL);

      assert
        .dom(".sitemap-autolink-admin__status .sitemap-autolink-admin__warning")
        .hasText(i18n("sitemap_autolink.admin.load_failed"));

      assert
        .dom(".sitemap-autolink-admin__entry")
        .exists({ count: 2 }, "the rest of the page still loads");
    });
  }
);

acceptance(
  "Sitemap Autolink | Admin catalog | plugin disabled",
  function (needs) {
    needs.user();
    needs.settings({ sitemap_autolink_enabled: false });

    needs.hooks.beforeEach(resetState);

    // With the plugin off, `requires_plugin` answers 404 for every one of
    // its endpoints — the exact state a first-time admin lands in.
    needs.pretender((server, helper) => {
      server.get(`${BASE}.json`, () => helper.response(pluginPayload()));
      ["status", "runs", "pending", "collisions", "entries"].forEach((path) =>
        server.get(`${BASE}/${path}`, () => helper.response(404, {}))
      );
    });

    test("names the cause instead of blaming the error log", async function (assert) {
      await visit(CATALOG_URL);

      assert
        .dom(".sitemap-autolink-admin__status .sitemap-autolink-admin__warning")
        .hasText(
          i18n("sitemap_autolink.admin.plugin_disabled"),
          "the page reads its own 404s as 'the plugin is disabled'"
        );
    });
  }
);
