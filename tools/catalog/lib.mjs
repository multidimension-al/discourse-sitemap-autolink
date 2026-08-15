// Pure logic for the GBFans autolink catalog generator: title extraction,
// alias generation, safety gates, collision resolution, client compilation
// and report rendering. No I/O here — build-catalog.mjs drives it.

const TITLE_SUFFIXES = [
  " - GBFans.com Wiki | GBFans.com",
  " - GBFans.com Wiki",
  " - GBFans.com Shop",
  " | GBFans.com",
  " - GBFans.com",
];

// Small embedded list of very common English words. Used only to FLAG
// suspicious single-word aliases in the report — never to silently drop.
export const COMMON_WORDS = new Set(
  (
    "the a an and or but if then else when while for to of in on at by with " +
    "from up down out over under again once here there all any both each few " +
    "more most other some such no nor not only own same so than too very can " +
    "will just should now new old good bad big small large little long short " +
    "high low right left first last next back front top bottom part parts " +
    "pack packs belt belts patch patches uniform uniforms suit suits glove " +
    "gloves boot boots shirt shirts hat hats pin pins kit kits set sets tube " +
    "tubing hose hoses wire wires label labels sticker stickers strap straps " +
    "clip clips knob knobs switch switches light lights sound sounds board " +
    "boards frame frames pad pads foam metal plastic resin rubber leather " +
    "screen accurate replica prop props movie film game games comic comics " +
    "book books toy toys card cards sign signs mug mugs cap caps shoe shoes " +
    "ghost ghosts slime slimer trap traps wand wands gun guns box boxes bag " +
    "bags case cases cover covers grip grips handle handles mount mounts " +
    "screw screws bolt bolts nut nuts washer washers spring springs magnet " +
    "magnets battery batteries charger speaker speakers amp amps volt volts " +
    "red blue green grey gray black white yellow orange brown purple pink " +
    "gold silver brass copper chrome dark bright clear solid custom official " +
    "vintage classic original special limited standard basic complete full " +
    "half quarter mini micro mega super ultra pro plus deluxe premium " +
    "guide guides news blog page pages home shop store wiki forum gallery " +
    "video videos photo photos image images music song songs episode episodes " +
    "season seasons character characters people person crew cast story " +
    "stories history location locations vehicle vehicles equipment gear " +
    "bank banks tank tanks barrel barrels bottle bottles glass glasses " +
    "poster posters banner banners button buttons badge badges keychain"
  ).split(/\s+/)
);

export function normalizeAlias(s) {
  return s
    .normalize("NFC")
    .replace(/[’‘]/g, "'")
    .replace(/[“”]/g, '"')
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

export function stripTitleSuffixes(title) {
  let t = title.trim();
  let changed = true;
  while (changed) {
    changed = false;
    for (const suffix of TITLE_SUFFIXES) {
      if (t.toLowerCase().endsWith(suffix.toLowerCase())) {
        t = t.slice(0, t.length - suffix.length).trim();
        changed = true;
      }
    }
  }
  return t;
}

const decodeEntities = (s) =>
  s
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;/g, "'")
    .replace(/&#x27;/gi, "'")
    .replace(/&apos;/g, "'")
    .replace(/&#0?38;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&");

// Extract the best available title from (possibly truncated) page HTML.
// Preference: og:title, then <title>; both get site suffixes stripped.
export function titleFromHtml(html) {
  const og = html.match(
    /<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']/i
  );
  const ogRev = html.match(
    /<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:title["']/i
  );
  const titleTag = html.match(/<title[^>]*>([^<]+)<\/title>/i);
  const raw =
    (og && og[1]) || (ogRev && ogRev[1]) || (titleTag && titleTag[1]) || null;
  if (!raw) {
    return null;
  }
  const cleaned = stripTitleSuffixes(decodeEntities(raw).trim());
  return cleaned === "" ? null : cleaned;
}

export function titleFromSlug(url) {
  const slug = url.replace(/\/+$/, "").split("/").pop() || "";
  const words = slug.split("-").filter(Boolean);
  return words
    .map((w) => (/^\d/.test(w) ? w : w[0].toUpperCase() + w.slice(1)))
    .join(" ");
}

// Generate alias variants for a title. Returns RAW variants (not yet
// normalized); the caller normalizes and applies gates so the report can
// account for what was dropped and why.
export function generateAliases(title, type) {
  const variants = new Set();
  const add = (v) => {
    v = v.replace(/\s+/g, " ").trim();
    if (v !== "") {
      variants.add(v);
    }
  };
  const base = title.replace(/\s+/g, " ").trim();
  add(base);

  // Product/category line prefixes: "Pack: ALICE Frame Padding"
  if (type === "product" || type === "category") {
    const m = base.match(/^([^:]{2,24}):\s+(.+)$/);
    if (m) {
      add(m[2]);
    }
  }

  // Trailing parentheticals: "Clippard Brass Elbow (GB1 Ion Arm)"
  for (const v of [...variants]) {
    const m = v.match(/^(.*\S)\s*\([^)]*\)$/);
    if (m) {
      add(m[1]);
    }
  }

  // Leading article for wiki-style titles
  for (const v of [...variants]) {
    if (/^the\s+/i.test(v)) {
      add(v.replace(/^the\s+/i, ""));
    }
  }

  // Conservative plural/singular variants. Adding "+s" is only useful for
  // product-ish names ("Grey Elbow Pad" -> "Grey Elbow Pads"); for wiki
  // proper nouns it just makes noise ("Vigo the Carpathians").
  for (const v of [...variants]) {
    if (!/s$/i.test(v)) {
      if (type === "product" || type === "category") {
        add(v + "s");
      }
    } else if (v.length > 5 && !/(ss|us|is)$/i.test(v)) {
      add(v.slice(0, -1));
    }
  }

  // "&" <-> "and"
  for (const v of [...variants]) {
    if (v.includes(" & ")) {
      add(v.replaceAll(" & ", " and "));
    } else if (/\sand\s/.test(v)) {
      add(v.replace(/\sand\s/g, " & "));
    }
  }

  return [...variants];
}

const wordCount = (s) => s.split(" ").filter(Boolean).length;

// "ecto-1", "gb1"-style tokens mix letters and digits; they are model
// names, not generic English, so they may pass the single-word wiki gate.
const isLetterDigitToken = (s) => /[a-z]/i.test(s) && /\d/.test(s);

const isCommonSingleWord = (alias) => {
  if (alias.includes(" ")) {
    return false;
  }
  const singular =
    alias.length >= 5 && /s$/.test(alias) && !/(ss|us|is)$/.test(alias)
      ? alias.slice(0, -1)
      : null;
  return COMMON_WORDS.has(alias) || (singular && COMMON_WORDS.has(singular));
};

// Build the full authoring-model entries plus the alias->entry winner map,
// applying gates and deterministic collision resolution.
// pages: [{url, type, title, titleSource, lastmod}]
// config: {typePriority, minAliasLength, minWikiTitleWords}
// overrides: {excludedAliases, manualAliases, urlOverrides, disabled,
//             priorityOverrides, extraEntries}
export function buildCatalog(pages, config, overrides) {
  const excluded = new Set(
    (overrides.excludedAliases || []).map(normalizeAlias)
  );
  const manual = overrides.manualAliases || {};
  const urlOverrides = overrides.urlOverrides || {};
  const disabled = new Set(overrides.disabled || []);
  const priorityOverrides = overrides.priorityOverrides || {};
  const rankOf = (type) => {
    const i = config.typePriority.indexOf(type);
    return i === -1 ? config.typePriority.length : i;
  };

  const entries = [];
  const stats = {
    excludedAliasHits: new Map(),
    tooShortAliases: new Map(),
    commonWordAliases: new Map(),
    singleWordWiki: [],
    slugDerivedTitles: [],
    disabledEntries: [],
  };

  const allPages = pages.concat(
    (overrides.extraEntries || []).map((e) => ({
      url: e.url,
      type: e.type,
      title: e.title,
      titleSource: "override",
      manualAliases: e.aliases || [],
    }))
  );

  for (const page of allPages) {
    if (!page.title) {
      continue;
    }
    let url = (urlOverrides[page.url] || page.url).replace(/\/+$/, "");
    const entry = {
      title: page.title,
      url,
      type: page.type,
      priority: priorityOverrides[url] ?? null,
      enabled: !disabled.has(url),
      titleSource: page.titleSource,
      aliases: [],
      flags: [],
    };
    if (page.titleSource === "slug") {
      entry.flags.push("slug-derived-title");
      stats.slugDerivedTitles.push(url);
    }
    if (!entry.enabled) {
      stats.disabledEntries.push(url);
    }

    const rawAliases = generateAliases(page.title, page.type).concat(
      page.manualAliases || []
    );
    const seen = new Set();
    for (const raw of rawAliases) {
      const alias = normalizeAlias(raw);
      if (alias === "" || seen.has(alias)) {
        continue;
      }
      seen.add(alias);
      if (excluded.has(alias)) {
        stats.excludedAliasHits.set(
          alias,
          (stats.excludedAliasHits.get(alias) || 0) + 1
        );
        continue;
      }
      if (alias.length < config.minAliasLength) {
        stats.tooShortAliases.set(
          alias,
          (stats.tooShortAliases.get(alias) || 0) + 1
        );
        continue;
      }
      // Generic English single words ("banks", "blues") are dropped
      // outright — linking them would be wrong far more often than right.
      if (config.excludeCommonSingleWords !== false && isCommonSingleWord(alias)) {
        stats.commonWordAliases.set(
          alias,
          (stats.commonWordAliases.get(alias) || 0) + 1
        );
        continue;
      }
      if (
        page.type === "wiki" &&
        wordCount(alias) < config.minWikiTitleWords &&
        !isLetterDigitToken(alias)
      ) {
        // Single-word wiki titles are flagged for manual vetting, never
        // auto-enabled ("Slime", "Containment Unit" passes, "Slimer" not).
        if (!stats.singleWordWiki.includes(entry.url)) {
          stats.singleWordWiki.push(entry.url);
        }
        entry.flags.includes("single-word-wiki") ||
          entry.flags.push("single-word-wiki");
        continue;
      }
      entry.aliases.push(alias);
    }
    entries.push(entry);
  }

  entries.sort((a, b) => (a.url < b.url ? -1 : a.url > b.url ? 1 : 0));

  // Alias -> candidate entries, then deterministic winner per alias.
  const candidates = new Map();
  for (const entry of entries) {
    if (!entry.enabled) {
      continue;
    }
    for (const alias of entry.aliases) {
      if (!candidates.has(alias)) {
        candidates.set(alias, []);
      }
      candidates.get(alias).push(entry);
    }
  }

  // Manual alias mappings always win and may add aliases of their own.
  const manualByAlias = new Map();
  for (const [rawAlias, url] of Object.entries(manual)) {
    manualByAlias.set(normalizeAlias(rawAlias), url.replace(/\/+$/, ""));
  }

  const winners = new Map();
  const collisions = [];
  for (const [alias, list] of [...candidates.entries()].sort()) {
    const manualUrl = manualByAlias.get(alias);
    if (manualUrl) {
      const entry = entries.find((e) => e.url === manualUrl);
      if (entry) {
        winners.set(alias, entry);
        if (list.length > 1 || (list.length === 1 && list[0] !== entry)) {
          collisions.push({
            alias,
            winner: entry.url,
            losers: list.filter((e) => e !== entry).map((e) => e.url),
            resolvedBy: "manual-override",
          });
        }
        continue;
      }
    }
    const sorted = [...list].sort(
      (a, b) =>
        (a.priority ?? rankOf(a.type)) - (b.priority ?? rankOf(b.type)) ||
        b.title.length - a.title.length ||
        (a.url < b.url ? -1 : 1)
    );
    winners.set(alias, sorted[0]);
    const distinctUrls = new Set(list.map((e) => e.url));
    if (distinctUrls.size > 1) {
      collisions.push({
        alias,
        winner: sorted[0].url,
        losers: sorted.slice(1).map((e) => e.url),
        resolvedBy: "priority",
      });
    }
  }

  // Manual aliases that point at an entry no generated alias covers
  for (const [alias, url] of manualByAlias.entries()) {
    if (!winners.has(alias)) {
      const entry = entries.find((e) => e.url === url);
      if (entry && entry.enabled) {
        winners.set(alias, entry);
        if (!entry.aliases.includes(alias)) {
          entry.aliases.push(alias);
        }
      }
    }
  }

  return { entries, winners, collisions, stats };
}

// Compact format the theme component downloads (see docs §3).
export function compileClientCatalog(build, generatedAt) {
  const { winners } = build;
  const usedEntries = [...new Set(winners.values())].sort((a, b) =>
    a.url < b.url ? -1 : 1
  );
  const types = [...new Set(usedEntries.map((e) => e.type))].sort();
  const indexOfEntry = new Map(usedEntries.map((e, i) => [e, i]));
  const aliases = {};
  for (const [alias, entry] of [...winners.entries()].sort()) {
    aliases[alias] = indexOfEntry.get(entry);
  }
  return {
    v: 1,
    generated: generatedAt,
    types,
    entries: usedEntries.map((e) => [e.url, types.indexOf(e.type)]),
    aliases,
  };
}

export function suspiciousAliases(build) {
  const out = [];
  for (const [alias, entry] of build.winners.entries()) {
    const words = alias.split(" ");
    const reasons = [];
    if (words.length === 1 && COMMON_WORDS.has(alias)) {
      reasons.push("common-english-word");
    }
    if (words.length === 1 && alias.length <= 6) {
      reasons.push("short-single-word");
    }
    if (words.every((w) => COMMON_WORDS.has(w)) && words.length <= 2) {
      reasons.push("all-common-words");
    }
    if (reasons.length > 0) {
      out.push({ alias, url: entry.url, type: entry.type, reasons });
    }
  }
  return out.sort((a, b) => (a.alias < b.alias ? -1 : 1));
}
