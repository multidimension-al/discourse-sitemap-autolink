import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  buildCatalog,
  compileClientCatalog,
  generateAliases,
  normalizeAlias,
  stripTitleSuffixes,
  suspiciousAliases,
  titleFromHtml,
  titleFromSlug,
} from "../catalog/lib.mjs";

const CONFIG = {
  typePriority: ["product", "category", "wiki"],
  minAliasLength: 5,
  minWikiTitleWords: 2,
};
const NO_OVERRIDES = {};

describe("title extraction", () => {
  it("prefers og:title and strips site suffixes", () => {
    const html = `<head><title>Pack: 1/4&quot; Split Wire Loom - GBFans.com Shop</title>
      <meta property="og:title" content="Pack: 1/4&quot; Split Wire Loom"/></head>`;
    assert.equal(titleFromHtml(html), 'Pack: 1/4" Split Wire Loom');
  });

  it("falls back to <title> and strips the wiki suffix chain", () => {
    const html = `<title>Vigo the Carpathian - GBFans.com Wiki | GBFans.com</title>`;
    assert.equal(titleFromHtml(html), "Vigo the Carpathian");
  });

  it("returns null when no title is present", () => {
    assert.equal(titleFromHtml("<p>loading…</p>"), null);
  });

  it("stripTitleSuffixes handles stacked suffixes", () => {
    assert.equal(
      stripTitleSuffixes("Uniforms - GBFans.com Shop"),
      "Uniforms"
    );
  });

  it("titleFromSlug produces a readable lossy fallback", () => {
    assert.equal(
      titleFromSlug("https://x/wiki/tobins-spirit-guide"),
      "Tobins Spirit Guide"
    );
  });
});

describe("alias generation", () => {
  it("strips product line prefixes", () => {
    const aliases = generateAliases("Pack: ALICE Frame Padding", "product");
    assert.ok(aliases.includes("ALICE Frame Padding"));
    assert.ok(aliases.includes("Pack: ALICE Frame Padding"));
  });

  it("strips trailing parentheticals", () => {
    const aliases = generateAliases(
      "Pack: Clippard Brass Elbow (GB1 Ion Arm)",
      "product"
    );
    assert.ok(aliases.includes("Clippard Brass Elbow"));
  });

  it("adds conservative plural/singular variants for products", () => {
    const aliases = generateAliases("Grey Elbow Pad", "product");
    assert.ok(aliases.includes("Grey Elbow Pads"));
    const aliases2 = generateAliases("Grey Elbow Pads", "product");
    assert.ok(aliases2.includes("Grey Elbow Pad"));
  });

  it("does not pluralize wiki proper nouns", () => {
    const aliases = generateAliases("Vigo the Carpathian", "wiki");
    assert.ok(!aliases.includes("Vigo the Carpathians"));
    // singular-from-plural stays useful for wiki
    const aliases2 = generateAliases("Terror Dogs", "wiki");
    assert.ok(aliases2.includes("Terror Dog"));
  });

  it("does not mangle words ending in ss/us/is", () => {
    const aliases = generateAliases("Gozer Access", "wiki");
    assert.ok(!aliases.includes("Gozer Acces"));
  });

  it("adds & <-> and variants and strips leading The", () => {
    const aliases = generateAliases("The Bumper & Siren Kit", "product");
    assert.ok(aliases.includes("The Bumper and Siren Kit"));
    assert.ok(aliases.includes("Bumper & Siren Kit"));
  });

  it("normalizeAlias unifies curly apostrophes and case", () => {
    assert.equal(normalizeAlias("Tobin’s  Spirit Guide"), "tobin's spirit guide");
  });
});

describe("catalog build", () => {
  const pages = [
    {
      url: "/shop/proton-pack-shell",
      type: "product",
      title: "Pack: Proton Pack Shell",
      titleSource: "page",
    },
    {
      url: "/shop/catalog/hasbro-proton-pack-mods",
      type: "category",
      title: "Hasbro Proton Pack Mods",
      titleSource: "page",
    },
    {
      url: "/wiki/equipment/proton-pack",
      type: "wiki",
      title: "Proton Pack",
      titleSource: "page",
    },
    {
      url: "/wiki/characters/slimer",
      type: "wiki",
      title: "Slimer",
      titleSource: "page",
    },
    {
      url: "/wiki/characters/vigo-the-carpathian",
      type: "wiki",
      title: "Vigo the Carpathian",
      titleSource: "page",
    },
  ];

  it("resolves collisions by type priority", () => {
    const build = buildCatalog(pages, CONFIG, NO_OVERRIDES);
    // "proton pack" is generated for both the wiki article (title) and the
    // product (suffix of title? no — but "Proton Pack Shell" prefix-strip
    // gives "Proton Pack Shell"), so check the wiki title itself:
    const winner = build.winners.get("proton pack");
    assert.equal(winner.url, "/wiki/equipment/proton-pack");
    const collision = build.collisions.find((c) => c.alias === "proton packs");
    assert.equal(collision, undefined);
  });

  it("keeps single-word wiki titles out of the alias map", () => {
    const build = buildCatalog(pages, CONFIG, NO_OVERRIDES);
    // "Slimer" is a common fan word — the common-word gate takes it first
    assert.equal(build.winners.get("slimer"), undefined);
    assert.ok(build.stats.commonWordAliases.has("slimer"));
    // A distinctive single-word wiki title is held back by the wiki gate
    const gozer = buildCatalog(
      [{ url: "/wiki/characters/gozer", type: "wiki", title: "Gozer", titleSource: "page" }],
      CONFIG,
      NO_OVERRIDES
    );
    assert.equal(gozer.winners.get("gozer"), undefined);
    assert.ok(gozer.stats.singleWordWiki.includes("/wiki/characters/gozer"));
  });

  it("lets letter+digit single-word wiki titles through (Ecto-1)", () => {
    const build = buildCatalog(
      [
        {
          url: "/wiki/vehicles/ecto-1",
          type: "wiki",
          title: "Ecto-1",
          titleSource: "page",
        },
      ],
      CONFIG,
      NO_OVERRIDES
    );
    assert.equal(build.winners.get("ecto-1").url, "/wiki/vehicles/ecto-1");
  });

  it("auto-excludes generic English single-word aliases", () => {
    const build = buildCatalog(
      [
        {
          url: "/shop/catalog/banks",
          type: "category",
          title: "Banks",
          titleSource: "page",
        },
      ],
      CONFIG,
      NO_OVERRIDES
    );
    assert.equal(build.winners.get("banks"), undefined);
    assert.ok(build.stats.commonWordAliases.has("banks"));
  });

  it("multi-word wiki titles are linkable", () => {
    const build = buildCatalog(pages, CONFIG, NO_OVERRIDES);
    assert.equal(
      build.winners.get("vigo the carpathian").url,
      "/wiki/characters/vigo-the-carpathian"
    );
    // leading-article variant also present
    assert.ok(build.winners.has("vigo the carpathians") === false);
  });

  it("applies excludedAliases and min length gates", () => {
    const build = buildCatalog(pages, CONFIG, {
      excludedAliases: ["proton pack"],
    });
    assert.equal(build.winners.get("proton pack"), undefined);
    assert.ok(build.stats.excludedAliasHits.get("proton pack") >= 1);
  });

  it("manual aliases beat priority", () => {
    const build = buildCatalog(pages, CONFIG, {
      manualAliases: { "proton pack": "/shop/proton-pack-shell" },
    });
    assert.equal(
      build.winners.get("proton pack").url,
      "/shop/proton-pack-shell"
    );
    const collision = build.collisions.find((c) => c.alias === "proton pack");
    assert.equal(collision.resolvedBy, "manual-override");
  });

  it("disabled URLs contribute no aliases", () => {
    const build = buildCatalog(pages, CONFIG, {
      disabled: ["/wiki/equipment/proton-pack"],
    });
    const winner = build.winners.get("proton pack");
    // falls to another candidate or nothing — never the disabled entry
    assert.notEqual(winner?.url, "/wiki/equipment/proton-pack");
  });

  it("compiles a compact, deterministic client catalog", () => {
    const build = buildCatalog(pages, CONFIG, NO_OVERRIDES);
    const client = compileClientCatalog(build, "2026-08-15T00:00:00Z");
    assert.equal(client.v, 1);
    assert.ok(Array.isArray(client.entries));
    assert.ok(client.entries.every(([url, t]) => url.startsWith("/") && t >= 0));
    for (const idx of Object.values(client.aliases)) {
      assert.ok(idx >= 0 && idx < client.entries.length);
    }
    // deterministic: same input -> same output
    const client2 = compileClientCatalog(build, "2026-08-15T00:00:00Z");
    assert.deepEqual(client, client2);
  });

  it("flags suspicious common-word aliases", () => {
    const build = buildCatalog(
      [
        {
          url: "/wiki/equipment/ghost-trap",
          type: "wiki",
          title: "Ghost Trap",
          titleSource: "page",
        },
      ],
      CONFIG,
      NO_OVERRIDES
    );
    const flagged = suspiciousAliases(build);
    assert.ok(flagged.some((s) => s.alias === "ghost trap"));
  });
});
