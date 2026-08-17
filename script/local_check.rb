# frozen_string_literal: true

# Standalone sanity harness: exercises Matcher + LinkApplier against
# cooked-style HTML with plain Ruby + Nokogiri, no Discourse boot.
#
#   ruby script/local_check.rb
#
# Exits non-zero on any failure.

require "nokogiri"
require_relative "../lib/sitemap_autolink/matcher"
require_relative "../lib/sitemap_autolink/ruleset"
require_relative "../lib/sitemap_autolink/link_applier"

RULES = [
  { phrase: "widget kit", url: "https://example.com/shop/widget-kit", type: "product", priority: 1 },
  { phrase: "gasket set", url: "https://example.com/shop/gasket-set", type: "product", priority: 1 },
  { phrase: "flux capacitor", url: "https://example.com/wiki/flux-capacitor", type: "wiki", priority: 3 },
  { phrase: "deluxe flux capacitor", url: "https://example.com/shop/deluxe-flux-capacitor", type: "category", priority: 2 },
  { phrase: "foreman's field guide", url: "https://example.com/wiki/foremans-field-guide", type: "wiki", priority: 3 },
].freeze

OPTIONS = { max_per_destination: 1, max_total: 0, skip_quotes: true }.freeze

$failures = 0

def check(name, cooked, options: OPTIONS, rules: RULES)
  doc = Nokogiri::HTML5.fragment(cooked)
  ruleset = SitemapAutolink::Ruleset.compile(rules)
  inserted = SitemapAutolink::LinkApplier.apply!(doc, ruleset, options)
  result = doc.to_html
  problems = yield(result, inserted)
  if problems.empty?
    puts "ok   #{name}"
  else
    $failures += 1
    puts "FAIL #{name}"
    problems.each { |p| puts "     - #{p}" }
    puts "     html: #{result}"
  end
end

def count_autolinks(html)
  html.scan("data-sitemap-autolink").size
end

check "links first occurrence only, once per post", <<~HTML do |html, inserted|
  <p>This widget kit works well.</p><p>I replaced my old widget kit.</p>
HTML
  problems = []
  problems << "expected 1 link, got #{inserted}" if inserted != 1
  unless html.include?('<a href="https://example.com/shop/widget-kit" class="sitemap-autolink sitemap-autolink-product"')
    problems << "missing expected link markup"
  end
  problems << "second paragraph was linked" if html.split("</p>")[1].to_s.include?("sitemap-autolink")
  problems
end

check "different destinations link in the same post", <<~HTML do |html, inserted|
  <p>I bought a widget kit and a gasket set.</p>
HTML
  problems = []
  problems << "expected 2 links, got #{inserted}" if inserted != 2
  problems << "missing gasket link" unless html.include?("/shop/gasket-set")
  problems
end

check "longest phrase wins overlaps", <<~HTML do |html, inserted|
  <p>My deluxe flux capacitor works. A bare flux capacitor too.</p>
HTML
  problems = []
  problems << "expected 2 links, got #{inserted}" if inserted != 2
  problems << "category link missing" unless html.include?("deluxe-flux-capacitor")
  problems << "wiki link missing for second occurrence" unless html.include?("/wiki/flux-capacitor")
  problems << "nested link inside link" if html.match?(/<a[^>]*>[^<]*<a/)
  problems
end

check "a page's budget buys its most specific mention",
      <<~HTML,
  <p>Any widget kit will do, but I fitted the deluxe widget kit.</p>
HTML
      rules:
        RULES +
          [
            {
              phrase: "deluxe widget kit",
              url: "https://example.com/shop/widget-kit",
              type: "product",
              priority: 1,
            },
          ] do |html, inserted|
  problems = []
  problems << "expected 1 link, got #{inserted}" if inserted != 1
  problems << "the stray early mention spent the budget" unless html.include?(">deluxe widget kit</a>")
  problems
end

check "a long phrase swallows the shorter ones inside it",
      <<~HTML,
  <p>I ordered the Acme Widget Kit Gasket Set today.</p>
HTML
      rules:
        RULES +
          [
            {
              phrase: "acme widget kit gasket set",
              url: "https://example.com/shop/acme-widget-kit-gasket-set",
              type: "product",
              priority: 1,
            },
          ] do |html, inserted|
  problems = []
  problems << "expected 1 link, got #{inserted}" if inserted != 1
  unless html.include?(">Acme Widget Kit Gasket Set</a>")
    problems << "the whole phrase was not linked as one"
  end
  problems << "an inner phrase linked separately" if html.include?("/shop/widget-kit")
  problems
end

check "a longer phrase starting later still wins",
      <<~HTML,
  <p>A widget kit deluxe frame is what I need.</p>
HTML
      rules:
        RULES +
          [
            {
              phrase: "kit deluxe frame",
              url: "https://example.com/shop/kit-deluxe-frame",
              type: "product",
              priority: 1,
            },
          ] do |html, inserted|
  problems = []
  problems << "expected 1 link, got #{inserted}" if inserted != 1
  problems << "the shorter earlier phrase won" unless html.include?("kit-deluxe-frame")
  problems
end

check "typographic apostrophe matches", <<~HTML do |html, inserted|
  <p>Check Foreman’s Field Guide for that part.</p>
HTML
  problems = []
  problems << "expected 1 link, got #{inserted}" if inserted != 1
  problems << "original curly apostrophe lost" unless html.include?("Foreman’s Field Guide</a>")
  problems
end

check "existing links, code, pre, quotes, onebox untouched", <<~HTML do |html, inserted|
  <p><a href="/x">widget kit</a> manual link</p>
  <pre><code>widget kit</code></pre>
  <aside class="quote"><blockquote><p>widget kit</p></blockquote></aside>
  <aside class="onebox"><p>widget kit</p></aside>
  <p>real widget kit</p>
HTML
  problems = []
  problems << "expected 1 link, got #{inserted}" if inserted != 1
  problems << "expected exactly one autolink" if count_autolinks(html) != 1
  problems << "quote was linkified" if html[/aside class="quote".*?<\/aside>/m].include?("sitemap-autolink")
  problems
end

check "quotes linkified when skip_quotes is off", <<~HTML, options: OPTIONS.merge(skip_quotes: false) do |html, inserted|
  <aside class="quote"><blockquote><p>widget kit</p></blockquote></aside>
HTML
  inserted == 1 ? [] : ["expected 1 link, got #{inserted}"]
end

check "total cap limits links", <<~HTML, options: OPTIONS.merge(max_total: 1) do |html, inserted|
  <p>widget kit and gasket set</p>
HTML
  inserted == 1 ? [] : ["expected 1 link, got #{inserted}"]
end

check "no substring matches inside words", <<~HTML do |html, inserted|
  <p>Kitbashing my toolkit with gaskets.</p>
HTML
  inserted.zero? ? [] : ["expected 0 links, got #{inserted}"]
end

check "html entities and attributes never corrupted", <<~HTML do |html, inserted|
  <p title="widget kit">Some &amp; text with widget kit &lt;tag&gt;</p>
HTML
  problems = []
  problems << "expected 1 link, got #{inserted}" if inserted != 1
  problems << "attribute got linkified" if html.include?('title="widget kit"') == false
  problems << "entity corrupted" unless html.include?("&amp;")
  problems
end

check "relative manual-mapping URLs pass through untouched", <<~HTML, rules: [{ phrase: "site faq", url: "/faq", type: "manual", priority: 0 }] do |html, inserted|
  <p>See the site FAQ for details.</p>
HTML
  problems = []
  problems << "expected 1 link, got #{inserted}" if inserted != 1
  problems << "relative href rewritten" unless html.include?('<a href="/faq"')
  problems
end

check "unsafe rule URLs never become links", <<~HTML, rules: [{ phrase: "evil widget", url: "javascript:alert(1)", type: "product", priority: 1 }, { phrase: "safe widget", url: "https://example.com/safe-widget", type: "product", priority: 1 }] do |html, inserted|
  <p>An evil widget next to a safe widget.</p>
HTML
  problems = []
  problems << "expected 1 link, got #{inserted}" if inserted != 1
  problems << "javascript: href emitted into HTML" if html.include?("javascript:")
  problems << "safe rule missing" unless html.include?("/safe-widget")
  problems
end

if $failures.zero?
  puts "\nall local checks passed"
else
  puts "\n#{$failures} check(s) FAILED"
  exit 1
end
