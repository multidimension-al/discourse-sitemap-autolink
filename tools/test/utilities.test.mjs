import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";
import { el, FakeElement, linksIn, serialize } from "./fake-dom.mjs";

// The theme runtime injects a `settings` global; provide it before the
// library functions (readInputList) look it up.
globalThis.settings = { linked_words: "" };

const {
  collectCandidates,
  linkifyElement,
  LinkCounter,
  readInputList,
  resolveOverlaps,
} = await import("../../javascripts/discourse-linkify/lib/utilities.js");

const SKIP_TAGS = { a: 1, iframe: 1, code: 1, pre: 1 };
const SKIP_CLASSES = { onebox: 1 };

const createLink = (text, url) =>
  el("a", { href: url, class: "linkify-word no-track-link" }, text);

function makeAction(inputs) {
  return { inputs, createNode: createLink };
}

function post(...paragraphs) {
  return el(
    "div",
    { class: "cooked" },
    ...paragraphs.map((p) => (typeof p === "string" ? el("p", {}, p) : p))
  );
}

function run(element, inputs, limits = { maxPerTerm: 1, maxTotal: 0 }) {
  linkifyElement(element, [makeAction(inputs)], SKIP_TAGS, SKIP_CLASSES, limits);
  return element;
}

describe("per-post limits", () => {
  it("links a term only once per post across paragraphs", () => {
    const element = post(
      "These elbow pads work well.",
      "I replaced my old elbow pads.",
      "Cheap elbow pads fall apart."
    );
    run(element, { "elbow pads": "/shop/uniform/grey-elbow-pads" });
    const links = linksIn(element);
    assert.equal(links.length, 1);
    assert.equal(links[0].text, "elbow pads");
    assert.equal(links[0].href, "/shop/uniform/grey-elbow-pads");
    // and it is the FIRST occurrence that got linked
    assert.match(serialize(element.childNodes[0]), /<a /);
    assert.doesNotMatch(serialize(element.childNodes[1]), /<a /);
    assert.doesNotMatch(serialize(element.childNodes[2]), /<a /);
  });

  it("links only the first of several occurrences in one paragraph", () => {
    const element = post(
      "These elbow pads work well. I replaced my old elbow pads."
    );
    run(element, { "elbow pads": "/shop/elbow" });
    assert.equal(linksIn(element).length, 1);
    assert.equal(
      serialize(element.childNodes[0]),
      '<p>These <a href="/shop/elbow" class="linkify-word no-track-link">elbow pads</a> work well. I replaced my old elbow pads.</p>'
    );
  });

  it("gives each post its own allowance", () => {
    const inputs = { "elbow pads": "/shop/elbow" };
    const first = run(post("Great elbow pads here."), inputs);
    const second = run(post("I also bought those elbow pads."), inputs);
    assert.equal(linksIn(first).length, 1);
    assert.equal(linksIn(second).length, 1);
  });

  it("still links different terms in the same post", () => {
    const element = post("These elbow pads work with my Alice frame padding.");
    run(element, {
      "elbow pads": "/shop/elbow",
      "Alice frame padding": "/shop/alice-frame-padding",
    });
    const links = linksIn(element);
    assert.deepEqual(
      links.map((l) => [l.text, l.href]),
      [
        ["elbow pads", "/shop/elbow"],
        ["Alice frame padding", "/shop/alice-frame-padding"],
      ]
    );
  });

  it("counts per destination, so aliases share one allowance", () => {
    const element = post("One elbow pad here.", "Two elbow pads there.");
    run(element, {
      "elbow pad": "/shop/elbow",
      "elbow pads": "/shop/elbow",
    });
    const links = linksIn(element);
    assert.equal(links.length, 1);
    assert.equal(links[0].text, "elbow pad");
  });

  it("honors a per-term limit greater than one", () => {
    const element = post("pack one", "pack two", "pack three");
    run(element, { pack: "/shop/pack" }, { maxPerTerm: 2, maxTotal: 0 });
    assert.equal(linksIn(element).length, 2);
  });

  it("honors a per-term limit greater than one inside a single paragraph", () => {
    const element = post("A pack, a pack, a pack.");
    run(element, { pack: "/shop/pack" }, { maxPerTerm: 2, maxTotal: 0 });
    assert.equal(linksIn(element).length, 2);
  });

  it("caps the total number of links per post", () => {
    const element = post("alpha beta gamma delta");
    run(
      element,
      { alpha: "/a", beta: "/b", gamma: "/c", delta: "/d" },
      { maxPerTerm: 1, maxTotal: 2 }
    );
    const links = linksIn(element);
    assert.deepEqual(
      links.map((l) => l.text),
      ["alpha", "beta"]
    );
  });

  it("does not double-link when an element is decorated twice", () => {
    const element = post("Nice elbow pads. More elbow pads.");
    const inputs = { "elbow pads": "/shop/elbow" };
    run(element, inputs);
    run(element, inputs);
    assert.equal(linksIn(element).length, 1);
  });
});

describe("match precedence", () => {
  it("prefers the longer phrase when one contains the other", () => {
    const element = post("My Hasbro proton pack arrived today.");
    run(element, {
      "proton pack": "/wiki/proton-pack",
      "Hasbro proton pack": "/shop/hasbro-proton-pack",
    });
    const links = linksIn(element);
    assert.equal(links.length, 1);
    assert.equal(links[0].text, "Hasbro proton pack");
    assert.equal(links[0].href, "/shop/hasbro-proton-pack");
  });

  it("prefers the longer phrase at the same start position", () => {
    const element = post("The proton pack is heavy.");
    run(element, {
      proton: "/wiki/proton",
      "proton pack": "/wiki/proton-pack",
    });
    const links = linksIn(element);
    assert.equal(links.length, 1);
    assert.equal(links[0].text, "proton pack");
  });

  it("links the shorter term elsewhere once the longer term won a span", () => {
    const element = post("The Hasbro proton pack beats a bare proton pack.");
    run(element, {
      "proton pack": "/wiki/proton-pack",
      "Hasbro proton pack": "/shop/hasbro-proton-pack",
    });
    const links = linksIn(element);
    assert.deepEqual(
      links.map((l) => l.text),
      ["Hasbro proton pack", "proton pack"]
    );
  });

  it("is case-insensitive and keeps the original casing in the text", () => {
    const element = post("VIGO the Carpathian appears.");
    run(element, { "vigo the carpathian": "/wiki/vigo" });
    const links = linksIn(element);
    assert.equal(links.length, 1);
    assert.equal(links[0].text, "VIGO the Carpathian");
  });

  it("does not match substrings inside words", () => {
    const element = post("Repacking backpacks quickly.");
    run(element, { pack: "/shop/pack" });
    assert.equal(linksIn(element).length, 0);
  });
});

describe("regex inputs", () => {
  it("supports regex entries with capture substitution", () => {
    const element = post("See ecto-1 and also ecto-2.");
    run(element, { "/ecto-(\\d+)/i": "https://gbfans.com/wiki/Ecto-$1" });
    const links = linksIn(element);
    assert.equal(links.length, 2);
    assert.equal(links[0].href, "https://gbfans.com/wiki/Ecto-1");
    assert.equal(links[1].href, "https://gbfans.com/wiki/Ecto-2");
  });

  it("caps regex matches per resolved destination", () => {
    const element = post("ecto-1 here", "ecto-1 again", "ecto-2 once");
    run(element, { "/ecto-(\\d+)/i": "https://gbfans.com/wiki/Ecto-$1" });
    const links = linksIn(element);
    assert.deepEqual(
      links.map((l) => l.href),
      ["https://gbfans.com/wiki/Ecto-1", "https://gbfans.com/wiki/Ecto-2"]
    );
  });

  it("terminates on regexes that can match empty strings", () => {
    const element = post("no ecks here");
    run(element, { "/x*/": "/x" });
    assert.equal(linksIn(element).length, 0);
  });
});

describe("legacy unlimited mode (max_links_per_term_per_post = 0)", () => {
  it("links the first occurrence in every paragraph", () => {
    const element = post(
      "elbow pads once, elbow pads twice.",
      "elbow pads again."
    );
    run(element, { "elbow pads": "/shop/elbow" }, { maxPerTerm: 0, maxTotal: 0 });
    // one per paragraph, only first within a paragraph — upstream behavior
    assert.equal(linksIn(element).length, 2);
  });

  it("links every regex occurrence", () => {
    const element = post("ecto-1 and ecto-1 and ecto-1");
    run(
      element,
      { "/ecto-(\\d+)/i": "/wiki/Ecto-$1" },
      { maxPerTerm: 0, maxTotal: 0 }
    );
    assert.equal(linksIn(element).length, 3);
  });
});

describe("exclusions", () => {
  it("never touches existing links, code, pre or excluded classes", () => {
    const element = el(
      "div",
      {},
      el("p", {}, el("a", { href: "/x" }, "elbow pads"), " and more"),
      el("p", {}, el("code", {}, "elbow pads")),
      el("pre", {}, "elbow pads"),
      el("aside", { class: "onebox whatever" }, el("p", {}, "elbow pads")),
      el("p", {}, "real elbow pads")
    );
    run(element, { "elbow pads": "/shop/elbow" });
    const links = linksIn(element).filter((l) =>
      (l.class || "").includes("linkify-word")
    );
    assert.equal(links.length, 1);
    assert.match(serialize(element.childNodes[4]), /linkify-word/);
  });
});

describe("building blocks", () => {
  beforeEach(() => {
    globalThis.settings = { linked_words: "" };
  });

  it("readInputList parses words, regexes and ignores malformed entries", () => {
    globalThis.settings = {
      linked_words:
        "elbow pads,/shop/elbow|/ecto-(\\d+),(\\d+)/i,/wiki/$1|broken-entry|,|x,",
    };
    const action = { inputListName: "linked_words", inputs: {} };
    readInputList(action);
    assert.deepEqual(action.inputs, {
      "elbow pads": "/shop/elbow",
      "/ecto-(\\d+),(\\d+)/i": "/wiki/$1",
    });
  });

  it("collectCandidates finds every occurrence when global", () => {
    const action = makeAction({ pack: "/p" });
    const candidates = collectCandidates("pack and pack", action, true);
    assert.equal(candidates.length, 2);
    assert.deepEqual(
      candidates.map((c) => c.start),
      [0, 9]
    );
  });

  it("resolveOverlaps keeps leftmost-longest matches", () => {
    const winners = resolveOverlaps([
      { start: 3, end: 14, text: "proton pack", value: "/a", order: 1 },
      { start: 10, end: 14, text: "pack", value: "/b", order: 2 },
      { start: 3, end: 9, text: "proton", value: "/c", order: 3 },
      { start: 20, end: 24, text: "pack", value: "/b", order: 2 },
    ]);
    assert.deepEqual(
      winners.map((w) => [w.start, w.text]),
      [
        [3, "proton pack"],
        [20, "pack"],
      ]
    );
  });

  it("LinkCounter enforces per-term and total limits", () => {
    const counter = new LinkCounter({ maxPerTerm: 1, maxTotal: 2 });
    assert.equal(counter.allows("/a"), true);
    counter.record("/a");
    assert.equal(counter.allows("/a"), false);
    assert.equal(counter.allows("/b"), true);
    counter.record("/b");
    assert.equal(counter.allows("/c"), false); // total cap reached
  });

  it("LinkCounter seeds from previously created links only", () => {
    const element = post(
      el(
        "p",
        {},
        el("a", { href: "/shop/elbow", class: "linkify-word no-track-link" }, "elbow pads"),
        " and ",
        el("a", { href: "/shop/elbow" }, "a manual link")
      )
    );
    const counter = new LinkCounter({ maxPerTerm: 1, maxTotal: 0 });
    counter.seed(element, "linkify-word");
    assert.equal(counter.total, 1);
    assert.equal(counter.allows("/shop/elbow"), false);
  });
});

// A FakeElement sanity check so DOM-level failures don't masquerade as
// linkify bugs.
describe("fake dom", () => {
  it("splitText behaves like the real thing", () => {
    const p = el("p", {}, "hello world");
    const text = p.childNodes[0];
    const rest = text.splitText(5);
    assert.equal(text.data, "hello");
    assert.equal(rest.data, " world");
    assert.equal(text.nextSibling, rest);
    assert.ok(p instanceof FakeElement);
  });
});
