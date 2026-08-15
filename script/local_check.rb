# frozen_string_literal: true

# Standalone sanity harness: exercises Matcher + LinkApplier against
# cooked-style HTML with plain Ruby + Nokogiri, no Discourse boot.
#
#   ruby script/local_check.rb
#
# Exits non-zero on any failure.

require "nokogiri"
require_relative "../lib/gbfans_autolink/matcher"
require_relative "../lib/gbfans_autolink/ruleset"
require_relative "../lib/gbfans_autolink/link_applier"

RULES = [
  { phrase: "elbow pads", url: "/shop/grey-elbow-pads", type: "product", priority: 1 },
  { phrase: "alice frame padding", url: "/shop/alice-frame-padding", type: "product", priority: 1 },
  { phrase: "proton pack", url: "/wiki/equipment/proton-pack", type: "wiki", priority: 3 },
  { phrase: "hasbro proton pack", url: "/shop/catalog/hasbro-proton-pack-mods", type: "category", priority: 2 },
  { phrase: "tobin's spirit guide", url: "/shop/tobins-spirit-guide", type: "product", priority: 1 },
].freeze

OPTIONS = {
  max_per_destination: 1,
  max_total: 0,
  skip_quotes: true,
  base_url: "https://www.gbfans.com",
}.freeze

$failures = 0

def check(name, cooked, options: OPTIONS, rules: RULES)
  doc = Nokogiri::HTML5.fragment(cooked)
  ruleset = GbfansAutolink::Ruleset.compile(rules)
  inserted = GbfansAutolink::LinkApplier.apply!(doc, ruleset, options)
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
  html.scan("data-gbfans-autolink").size
end

check "links first occurrence only, once per post", <<~HTML do |html, inserted|
  <p>These elbow pads work well.</p><p>I replaced my old elbow pads.</p>
HTML
  problems = []
  problems << "expected 1 link, got #{inserted}" if inserted != 1
  unless html.include?('<a href="https://www.gbfans.com/shop/grey-elbow-pads" class="gbfans-autolink gbfans-autolink-product"')
    problems << "missing expected link markup"
  end
  problems << "second paragraph was linked" if html.split("</p>")[1].to_s.include?("gbfans-autolink")
  problems
end

check "different destinations link in the same post", <<~HTML do |html, inserted|
  <p>I bought elbow pads and Alice frame padding.</p>
HTML
  problems = []
  problems << "expected 2 links, got #{inserted}" if inserted != 2
  problems << "missing alice link" unless html.include?("/shop/alice-frame-padding")
  problems
end

check "longest phrase wins overlaps", <<~HTML do |html, inserted|
  <p>My Hasbro proton pack works. A bare proton pack too.</p>
HTML
  problems = []
  problems << "expected 2 links, got #{inserted}" if inserted != 2
  problems << "hasbro category link missing" unless html.include?("hasbro-proton-pack-mods")
  problems << "wiki link missing for second occurrence" unless html.include?("/wiki/equipment/proton-pack")
  problems << "nested link inside link" if html.match?(/<a[^>]*>[^<]*<a/)
  problems
end

check "typographic apostrophe matches", <<~HTML do |html, inserted|
  <p>Check Tobin’s Spirit Guide for that ghost.</p>
HTML
  problems = []
  problems << "expected 1 link, got #{inserted}" if inserted != 1
  problems << "original curly apostrophe lost" unless html.include?("Tobin’s Spirit Guide</a>")
  problems
end

check "existing links, code, pre, quotes, onebox untouched", <<~HTML do |html, inserted|
  <p><a href="/x">elbow pads</a> manual link</p>
  <pre><code>elbow pads</code></pre>
  <aside class="quote"><blockquote><p>elbow pads</p></blockquote></aside>
  <aside class="onebox"><p>elbow pads</p></aside>
  <p>real elbow pads</p>
HTML
  problems = []
  problems << "expected 1 link, got #{inserted}" if inserted != 1
  problems << "expected exactly one autolink" if count_autolinks(html) != 1
  problems << "quote was linkified" if html[/aside class="quote".*?<\/aside>/m].include?("gbfans-autolink")
  problems
end

check "quotes linkified when skip_quotes is off", <<~HTML, options: OPTIONS.merge(skip_quotes: false) do |html, inserted|
  <aside class="quote"><blockquote><p>elbow pads</p></blockquote></aside>
HTML
  inserted == 1 ? [] : ["expected 1 link, got #{inserted}"]
end

check "total cap limits links", <<~HTML, options: OPTIONS.merge(max_total: 1) do |html, inserted|
  <p>elbow pads and Alice frame padding</p>
HTML
  inserted == 1 ? [] : ["expected 1 link, got #{inserted}"]
end

check "no substring matches inside words", <<~HTML do |html, inserted|
  <p>Repacking my backpack with proton packs.</p>
HTML
  inserted.zero? ? [] : ["expected 0 links, got #{inserted}"]
end

check "html entities and attributes never corrupted", <<~HTML do |html, inserted|
  <p title="elbow pads">Some &amp; text with elbow pads &lt;tag&gt;</p>
HTML
  problems = []
  problems << "expected 1 link, got #{inserted}" if inserted != 1
  problems << "attribute got linkified" if html.include?('title="elbow pads"') == false
  problems << "entity corrupted" unless html.include?("&amp;")
  problems
end

if $failures.zero?
  puts "\nall local checks passed"
else
  puts "\n#{$failures} check(s) FAILED"
  exit 1
end
