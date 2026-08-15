#!/usr/bin/env node
// GBFans autolink catalog builder.
//
//   node tools/catalog/build-catalog.mjs [--config=path] [--max-pages=N]
//        [--types=product,category] [--no-fetch] [--refetch]
//
// Enumerates canonical URLs from the segmented sitemaps, resolves exact
// titles from each page's metadata (og:title / <title>, read with an
// early-abort stream so only the needed prefix of each page transfers),
// then compiles the client catalog and a quality report. See
// docs/INTERNAL_LINKING.md for the architecture.

import { gzipSync } from "node:zlib";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  buildCatalog,
  compileClientCatalog,
  suspiciousAliases,
  titleFromHtml,
  titleFromSlug,
} from "./lib.mjs";

const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    const m = a.match(/^--([^=]+)(?:=(.*))?$/);
    return m ? [m[1], m[2] ?? true] : [a, true];
  })
);

const configPath = resolve(
  args.config || join(dirname(fileURLToPath(import.meta.url)), "config.json")
);
const baseDir = dirname(configPath);
const config = JSON.parse(await readFile(configPath, "utf8"));
const overrides = JSON.parse(
  await readFile(resolve(baseDir, config.overrides), "utf8")
);
const cacheDir = resolve(baseDir, config.cacheDir);
const distDir = resolve(baseDir, config.distDir);
const cachePath = join(cacheDir, "titles.json");

await mkdir(cacheDir, { recursive: true });
await mkdir(distDir, { recursive: true });

let cache = {};
if (!args.refetch) {
  try {
    cache = JSON.parse(await readFile(cachePath, "utf8"));
  } catch {
    cache = {};
  }
}

const log = (msg) => process.stderr.write(`${msg}\n`);

// ---------------------------------------------------------------- sitemaps

async function fetchText(url) {
  const res = await fetch(url, {
    headers: { "user-agent": config.fetch.userAgent, accept: "*/*" },
  });
  if (!res.ok) {
    throw new Error(`${url} -> HTTP ${res.status}`);
  }
  return res.text();
}

function parseSitemap(xml) {
  const urls = [];
  for (const block of xml.split(/<\/url>/i)) {
    const loc = block.match(/<loc>\s*([^<\s]+)\s*<\/loc>/i);
    if (!loc) {
      continue;
    }
    const lastmod = block.match(/<lastmod>\s*([^<\s]+)\s*<\/lastmod>/i);
    urls.push({ loc: loc[1], lastmod: lastmod ? lastmod[1] : null });
  }
  return urls;
}

// ------------------------------------------------------------- page titles

async function fetchTitle(url, maxBytes) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), config.fetch.timeoutMs);
  try {
    const res = await fetch(url, {
      headers: { "user-agent": config.fetch.userAgent, accept: "text/html" },
      redirect: "follow",
      signal: controller.signal,
    });
    if (!res.ok) {
      return { status: res.status, title: null };
    }
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let html = "";
    for (;;) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      html += decoder.decode(value, { stream: true });
      if (/<\/title>/i.test(html)) {
        const title = titleFromHtml(html);
        if (title) {
          await reader.cancel().catch(() => {});
          return { status: 200, title, bytes: html.length };
        }
      }
      if (html.length >= maxBytes) {
        await reader.cancel().catch(() => {});
        break;
      }
    }
    return { status: 200, title: titleFromHtml(html), bytes: html.length };
  } finally {
    clearTimeout(timer);
  }
}

async function resolveTitles(items) {
  const queue = [...items];
  let done = 0;
  let failures = 0;
  const total = queue.length;
  const worker = async () => {
    for (;;) {
      const item = queue.shift();
      if (!item) {
        return;
      }
      const cached = cache[item.url];
      const fresh =
        cached &&
        cached.title &&
        cached.titleSource === "page" &&
        (!item.lastmod || cached.lastmod === item.lastmod);
      if (!fresh && !args["no-fetch"]) {
        let result = null;
        for (let attempt = 0; attempt < 2 && !result?.title; attempt++) {
          try {
            result = await fetchTitle(item.url, item.maxBytes);
            if (result.status >= 500) {
              result = null;
              await new Promise((r) => setTimeout(r, 1500));
            }
          } catch {
            result = null;
            await new Promise((r) => setTimeout(r, 1500));
          }
        }
        if (result?.title) {
          cache[item.url] = {
            title: result.title,
            titleSource: "page",
            status: result.status,
            lastmod: item.lastmod,
            fetchedAt: new Date().toISOString(),
          };
        } else {
          failures++;
          cache[item.url] = {
            title: titleFromSlug(item.url),
            titleSource: "slug",
            status: result?.status ?? 0,
            lastmod: item.lastmod,
            fetchedAt: new Date().toISOString(),
          };
        }
        await new Promise((r) => setTimeout(r, config.fetch.delayMs));
      } else if (!cached) {
        cache[item.url] = {
          title: titleFromSlug(item.url),
          titleSource: "slug",
          status: 0,
          lastmod: item.lastmod,
          fetchedAt: null,
        };
      }
      done++;
      if (done % 100 === 0 || done === total) {
        log(`  titles: ${done}/${total} (fetch failures so far: ${failures})`);
        await writeFile(cachePath, JSON.stringify(cache));
      }
    }
  };
  await Promise.all(
    Array.from({ length: config.fetch.concurrency }, () => worker())
  );
  await writeFile(cachePath, JSON.stringify(cache));
}

// ------------------------------------------------------------------- main

const typeFilter = args.types ? String(args.types).split(",") : null;
const maxPages = args["max-pages"] ? Number(args["max-pages"]) : Infinity;

const pages = [];
for (const source of config.sources) {
  if (typeFilter && !typeFilter.includes(source.type)) {
    continue;
  }
  const sitemapUrl = config.baseUrl + source.sitemap;
  log(`sitemap ${sitemapUrl} …`);
  const urls = parseSitemap(await fetchText(sitemapUrl)).slice(0, maxPages);
  log(`  ${urls.length} URLs (${source.type})`);
  for (const { loc, lastmod } of urls) {
    pages.push({
      url: loc,
      lastmod,
      type: source.type,
      maxBytes: source.maxBytes || 65536,
    });
  }
}

log(`resolving titles for ${pages.length} pages …`);
await resolveTitles(pages);

const pageModels = pages.map((p) => ({
  url: p.url.replace(config.baseUrl, ""),
  type: p.type,
  title: cache[p.url]?.title ?? null,
  titleSource: cache[p.url]?.titleSource ?? "missing",
  lastmod: p.lastmod,
}));

const build = buildCatalog(pageModels, config, overrides);
const generatedAt = new Date().toISOString();
const client = compileClientCatalog(build, generatedAt);
const suspicious = suspiciousAliases(build);

const clientJson = JSON.stringify(client);
const gzBytes = gzipSync(Buffer.from(clientJson)).length;

// ------------------------------------------------------------------ report

const byType = (type) => build.entries.filter((e) => e.type === type);
const aliasCountByType = (type) =>
  [...build.winners.values()].filter((e) => e.type === type).length;
const fetchFailures = pageModels.filter((p) => p.titleSource === "slug");

const fmt = (n) => n.toLocaleString("en-US");
const lines = [];
lines.push(`# GBFans autolink catalog report`);
lines.push(``);
lines.push(`Generated: ${generatedAt}`);
lines.push(``);
lines.push(`## Inventory`);
lines.push(``);
lines.push(`| Type | Source URLs | Entries | Linkable aliases |`);
lines.push(`| --- | --- | --- | --- |`);
for (const type of config.typePriority) {
  const entries = byType(type);
  if (entries.length === 0 && !pageModels.some((p) => p.type === type)) {
    continue;
  }
  lines.push(
    `| ${type} | ${fmt(pageModels.filter((p) => p.type === type).length)} | ${fmt(
      entries.length
    )} | ${fmt(aliasCountByType(type) || 0)} |`
  );
}
lines.push(
  `| **total** | **${fmt(pageModels.length)}** | **${fmt(
    build.entries.length
  )}** | **${fmt(build.winners.size)}** |`
);
lines.push(``);
lines.push(`## Client catalog size`);
lines.push(``);
lines.push(`- raw JSON: **${fmt(clientJson.length)} bytes**`);
lines.push(`- gzipped: **${fmt(gzBytes)} bytes**`);
lines.push(``);
lines.push(`## Collisions (${fmt(build.collisions.length)})`);
lines.push(``);
lines.push(
  `Aliases claimed by more than one destination; winner chosen by ` +
    `priority (${config.typePriority.join(" > ")}), then longer title, ` +
    `then URL. Full list below — review losers that deserve a manual alias.`
);
lines.push(``);
for (const c of build.collisions.slice(0, 200)) {
  lines.push(
    `- \`${c.alias}\` → **${c.winner}** (over ${c.losers.join(", ")})` +
      (c.resolvedBy === "manual-override" ? ` _(manual override)_` : "")
  );
}
if (build.collisions.length > 200) {
  lines.push(`- … ${fmt(build.collisions.length - 200)} more`);
}
lines.push(``);
lines.push(`## Suspicious / too-generic aliases (${fmt(suspicious.length)})`);
lines.push(``);
lines.push(
  `Currently **enabled** aliases that look risky (common English words or ` +
    `very short). Add the bad ones to \`excludedAliases\` in overrides.json.`
);
lines.push(``);
for (const s of suspicious.slice(0, 200)) {
  lines.push(`- \`${s.alias}\` → ${s.url} (${s.reasons.join(", ")})`);
}
if (suspicious.length > 200) {
  lines.push(`- … ${fmt(suspicious.length - 200)} more`);
}
lines.push(``);
lines.push(
  `## Single-word wiki titles kept OUT of the catalog (${fmt(
    build.stats.singleWordWiki.length
  )})`
);
lines.push(``);
lines.push(
  `Held back by min_wiki_title_words=${config.minWikiTitleWords}. Vet and ` +
    `promote the safe ones via manualAliases.`
);
lines.push(``);
for (const url of build.stats.singleWordWiki.slice(0, 100)) {
  lines.push(`- ${url}`);
}
if (build.stats.singleWordWiki.length > 100) {
  lines.push(`- … ${fmt(build.stats.singleWordWiki.length - 100)} more`);
}
lines.push(``);
lines.push(`## Gates`);
lines.push(``);
lines.push(
  `- aliases dropped by excludedAliases: ${fmt(
    [...build.stats.excludedAliasHits.values()].reduce((a, b) => a + b, 0)
  )} hits across ${fmt(build.stats.excludedAliasHits.size)} terms`
);
lines.push(
  `- aliases dropped for length < ${config.minAliasLength}: ${fmt(
    [...build.stats.tooShortAliases.values()].reduce((a, b) => a + b, 0)
  )} (${fmt(build.stats.tooShortAliases.size)} distinct)`
);
lines.push(
  `- generic single-word aliases auto-excluded: ${fmt(
    [...build.stats.commonWordAliases.values()].reduce((a, b) => a + b, 0)
  )} (${fmt(build.stats.commonWordAliases.size)} distinct: ${[
    ...build.stats.commonWordAliases.keys(),
  ]
    .sort()
    .slice(0, 30)
    .map((a) => `\`${a}\``)
    .join(", ")})`
);
lines.push(`- entries disabled via overrides: ${fmt(build.stats.disabledEntries.length)}`);
lines.push(``);
lines.push(`## Title fetch failures → slug-derived titles (${fmt(fetchFailures.length)})`);
lines.push(``);
lines.push(
  `These titles are LOSSY (no punctuation/case). Re-run the builder to ` +
    `retry, or fix manually via extraEntries.`
);
for (const p of fetchFailures.slice(0, 100)) {
  lines.push(`- ${p.url}`);
}
lines.push(``);

await writeFile(join(distDir, "catalog.json"), clientJson);
await writeFile(
  join(distDir, "catalog-source.json"),
  JSON.stringify(
    {
      generated: generatedAt,
      config: {
        typePriority: config.typePriority,
        minAliasLength: config.minAliasLength,
        minWikiTitleWords: config.minWikiTitleWords,
      },
      entries: build.entries,
    },
    null,
    1
  )
);
await writeFile(join(distDir, "report.md"), lines.join("\n"));

log(`\nwrote ${join(distDir, "catalog.json")} (${fmt(clientJson.length)} B raw / ${fmt(gzBytes)} B gz)`);
log(`wrote ${join(distDir, "catalog-source.json")}`);
log(`wrote ${join(distDir, "report.md")}`);
log(
  `entries: ${fmt(build.entries.length)}  aliases: ${fmt(
    build.winners.size
  )}  collisions: ${fmt(build.collisions.length)}  suspicious: ${fmt(
    suspicious.length
  )}`
);
