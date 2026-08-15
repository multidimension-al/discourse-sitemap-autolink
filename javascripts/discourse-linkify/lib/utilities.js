const readInputList = function (action) {
  if (settings[action.inputListName].trim() === "") {
    return;
  }
  settings[action.inputListName].split("|").forEach((pair) => {
    if (!pair.includes(",")) {
      return;
    }
    let split = pair.split(",");
    let value = split.pop().trim();
    // We want to allow commas in regexes
    let word = split.join(",").trim();
    if (value === "" || word === "") {
      return;
    }
    action.inputs[word] = value;
  });
};

// Detect this pattern: /regex/modifiers
const isInputRegex = function (input) {
  if (input[0] === "/" && input.split("/").length > 2) {
    return true;
  } else {
    return false;
  }
};

const escapeRegExp = function (str) {
  return str.replace(/[\-\[\]\/\{\}\(\)\*\+\?\.\\\^\$\|]/g, "\\$&");
};

const prepareRegex = function (input, wordsGlobal) {
  let leftWordBoundary = "(\\s|[:.;,!?…\\([{]|^)";
  let rightWordBoundary = "(?=[:.;,!?…\\]})]|\\s|$)";
  let wordOrRegex, modifier, regex;
  if (isInputRegex(input)) {
    let tmp = input.split("/");
    modifier = tmp.pop();
    wordOrRegex = tmp.slice(1).join("/");
    // Allow only "i" modifier for now, global modifier is implicit
    if (modifier.includes("i")) {
      modifier = "ig";
    } else {
      modifier = "g";
    }
  } else {
    // Input is a case-insensitive WORD.
    // Without per-post limits we only autolink the first occurrence in each
    // text node, i.e. do not use the global modifier. When per-post limits
    // are active we need every occurrence as a candidate and let the
    // per-post counter decide how many actually become links.
    modifier = wordsGlobal ? "ig" : "i";
    wordOrRegex = escapeRegExp(input);
  }
  try {
    regex = new RegExp(
      leftWordBoundary + "(" + wordOrRegex + ")" + rightWordBoundary,
      modifier
    );
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error(
      "ERROR from auto-linkify theme: Invalid input:",
      wordOrRegex,
      err.message
    );
    return;
  }
  return regex;
};

const replaceCapturedVariables = function (input, match) {
  // Did we capture user defined variables?
  // By default, we capture 2 vars: left boundary and the regex itself
  if (match.length <= 3) {
    return input;
  }
  let captured = match.slice(3, match.length);
  let replaced = input;
  for (let i = captured.length; i > 0; i--) {
    let re = new RegExp("\\$" + i.toString(), "");
    replaced = replaced.replace(re, captured[i - 1]);
  }
  return replaced;
};

// Collect every potential match of the action's inputs against a string.
// Regex inputs are matched in their configured order first, then plain
// words longest first, so that the returned `order` value encodes the
// precedence of the entry that produced each candidate.
const collectCandidates = function (str, action, wordsGlobal) {
  const words = action.inputs;
  const inputRegexes = Object.keys(words).filter(isInputRegex);
  const sortedWords = Object.keys(words)
    .filter((x) => !isInputRegex(x))
    .sort((x, y) => y.length - x.length);
  const keys = inputRegexes.concat(sortedWords);
  const candidates = [];
  for (let order = 0; order < keys.length; order++) {
    const key = keys[order];
    const regex = prepareRegex(key, wordsGlobal);
    if (!(regex instanceof RegExp)) {
      continue;
    }
    let match;
    while ((match = regex.exec(str)) !== null) {
      const matchedWord = match[2];
      if (matchedWord) {
        const start = match.index + match[1].length;
        const value = replaceCapturedVariables(words[key], match);
        candidates.push({
          start,
          end: start + matchedWord.length,
          text: matchedWord,
          value,
          order,
        });
      }
      if (!regex.global) {
        break;
      }
      // Protect against zero-length matches looping forever
      if (match.index === regex.lastIndex) {
        regex.lastIndex++;
      }
    }
  }
  return candidates;
};

// Deterministically resolve overlapping candidates: the leftmost match
// wins; on a tie the longer (more specific) match wins; on a further tie
// the entry precedence (regexes in configured order, then words longest
// first) wins. A span claimed by a winning candidate is not re-awarded to
// shorter overlapping candidates even if the winner is later dropped by a
// per-post limit — that keeps the outcome independent of counter state.
const resolveOverlaps = function (candidates) {
  const sorted = candidates.sort(
    (a, b) =>
      a.start - b.start ||
      b.end - b.start - (a.end - a.start) ||
      a.order - b.order
  );
  const winners = [];
  let lastEnd = -1;
  for (const candidate of sorted) {
    if (candidate.start >= lastEnd) {
      winners.push(candidate);
      lastEnd = candidate.end;
    }
  }
  return winners;
};

// Tracks how many auto-links have been created in the current post, in
// total and per destination. maxPerTerm/maxTotal of 0 mean "no limit".
class LinkCounter {
  constructor({ maxPerTerm = 0, maxTotal = 0 } = {}) {
    this.maxPerTerm = maxPerTerm;
    this.maxTotal = maxTotal;
    this.perTerm = new Map();
    this.total = 0;
  }

  get unlimited() {
    return this.maxPerTerm === 0 && this.maxTotal === 0;
  }

  allows(key) {
    if (this.maxTotal > 0 && this.total >= this.maxTotal) {
      return false;
    }
    if (
      this.maxPerTerm > 0 &&
      (this.perTerm.get(key) || 0) >= this.maxPerTerm
    ) {
      return false;
    }
    return true;
  }

  record(key) {
    this.perTerm.set(key, (this.perTerm.get(key) || 0) + 1);
    this.total++;
  }

  // Count links a previous decoration pass already created inside this
  // element, so running again never exceeds the per-post limits.
  seed(elem, linkClass) {
    for (let i = 0; i < elem.childNodes.length; i++) {
      const child = elem.childNodes[i];
      if (child.nodeType !== 1) {
        continue;
      }
      const cls = child.getAttribute("class");
      if (
        child.nodeName.toLowerCase() === "a" &&
        cls &&
        cls.split(" ").includes(linkClass)
      ) {
        this.record(child.getAttribute("href"));
      } else {
        this.seed(child, linkClass);
      }
    }
  }
}

const isSkippedClass = function (classes, skipClasses) {
  // Return true if at least one of the classes should be skipped
  return classes && classes.split(" ").some((cls) => cls in skipClasses);
};

// Collect text nodes in document order, honoring skipped tags/classes.
// Collecting up front means later DOM mutations cannot break iteration.
const collectTextNodes = function (elem, skipTags, skipClasses, textNodes) {
  for (let i = 0; i < elem.childNodes.length; i++) {
    const child = elem.childNodes[i];
    if (child.nodeType === 1) {
      const tag = child.nodeName.toLowerCase();
      const cls = child.getAttribute("class");
      if (!(tag in skipTags) && !isSkippedClass(cls, skipClasses)) {
        collectTextNodes(child, skipTags, skipClasses, textNodes);
      }
    } else if (child.nodeType === 3) {
      textNodes.push(child);
    }
  }
  return textNodes;
};

// Wrap the accepted matches of a single text node. Matches must be
// non-overlapping; they are applied right-to-left so earlier offsets keep
// pointing at the right characters while the node is split up.
const applyMatches = function (text, matches, action) {
  const sorted = matches.sort((a, b) => b.start - a.start);
  for (const match of sorted) {
    if (match.end > text.data.length) {
      continue;
    }
    text.splitText(match.start);
    text.nextSibling.splitText(match.text.length);
    text.parentNode.replaceChild(
      action.createNode(match.text, match.value),
      text.nextSibling
    );
  }
};

// Process one cooked element (one post) for the given actions.
// Every action shares one per-post counter, and the counter is seeded
// with links from any earlier pass over the same element, so each
// destination gets a single per-post allowance no matter how often the
// element is decorated.
const linkifyElement = function (
  element,
  actions,
  skipTags,
  skipClasses,
  limits
) {
  const counter = new LinkCounter(limits);
  if (!counter.unlimited) {
    counter.seed(element, "linkify-word");
  }
  actions.forEach((action) => {
    if (Object.keys(action.inputs).length === 0) {
      return;
    }
    const textNodes = collectTextNodes(element, skipTags, skipClasses, []);
    for (const text of textNodes) {
      const candidates = collectCandidates(
        text.data,
        action,
        !counter.unlimited
      );
      if (candidates.length === 0) {
        continue;
      }
      const winners = resolveOverlaps(candidates);
      // Winners arrive sorted by position; consume the per-post allowance
      // in document order so the FIRST occurrence in the post is the one
      // that gets linked.
      const accepted = [];
      for (const winner of winners) {
        if (counter.allows(winner.value)) {
          counter.record(winner.value);
          accepted.push(winner);
        }
      }
      if (accepted.length > 0) {
        applyMatches(text, accepted, action);
      }
    }
  });
};

export {
  applyMatches,
  collectCandidates,
  collectTextNodes,
  LinkCounter,
  linkifyElement,
  prepareRegex,
  readInputList,
  resolveOverlaps,
};
