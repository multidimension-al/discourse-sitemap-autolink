# frozen_string_literal: true

# Benchmarks the Aho-Corasick matcher and the full HTML apply pass with a
# realistic catalog. No Discourse boot needed.
#
#   ruby script/benchmark_matcher.rb [catalog.json]
#
# catalog.json is the compiled catalog produced by tools/catalog (the
# format documented in docs/INTERNAL_LINKING.md). Without one, 5,500
# synthetic phrases are generated instead.

require "json"
require "benchmark"
require_relative "../lib/gbfans_autolink/matcher"
require_relative "../lib/gbfans_autolink/ruleset"

begin
  require "nokogiri"
  NOKOGIRI = true
rescue LoadError
  NOKOGIRI = false
end
require_relative "../lib/gbfans_autolink/link_applier" if NOKOGIRI

def load_rules(path)
  if path && File.exist?(path)
    catalog = JSON.parse(File.read(path))
    types = catalog["types"]
    catalog["aliases"].map do |phrase, entry_index|
      url, type_index = catalog["entries"][entry_index]
      {
        phrase: GbfansAutolink::Matcher.normalize(phrase),
        url: url,
        type: types[type_index],
        priority: type_index + 1,
      }
    end
  else
    words = %w[
      proton neutrino ecto ghost spirit trap pack wand frame padding elbow
      grey uniform belt hose gizmo spectral plasm slime tobin vigo zuul
      keymaster gatekeeper containment cyclotron thrower bumper shell
    ]
    (1..5_500).map do |i|
      phrase = "#{words[i % words.size]} #{words[(i / words.size) % words.size]} #{i}"
      { phrase: phrase, url: "/x/#{i}", type: "product", priority: 1 }
    end
  end
end

def make_post_text(chars, rules)
  filler = <<~TEXT.gsub("\n", " ")
    I finally finished my build this weekend and took it to the local con.
    The mobility is way better than my previous setup and several people
    asked where the parts came from, which honestly surprised me a bit.
  TEXT
  text = +""
  i = 0
  while text.length < chars
    text << filler
    if (i += 1) % 3 == 0
      text << " I used #{rules[i * 37 % rules.size][:phrase]} for that. "
    end
  end
  text[0, chars]
end

rules = load_rules(ARGV[0])
puts "phrases: #{rules.size}"

matcher = nil
build = Benchmark.realtime { matcher = GbfansAutolink::Matcher.new(rules) }
puts format("automaton build: %.1f ms", build * 1000)

[500, 2_000, 10_000].each do |size|
  text = GbfansAutolink::Matcher.normalize(make_post_text(size, rules))
  iterations = size > 5_000 ? 200 : 500
  # warmup
  10.times { matcher.scan(text) }
  elapsed = Benchmark.realtime { iterations.times { matcher.scan(text) } }
  per_scan = elapsed / iterations * 1000
  hits = matcher.scan(text).size
  puts format(
         "scan %6d chars: %8.3f ms/post  (%5.0f posts/sec, %d candidate hits)",
         size,
         per_scan,
         1000 / per_scan,
         hits,
       )
end

if NOKOGIRI
  ruleset = GbfansAutolink::Ruleset.compile(rules)
  ruleset.matcher # pre-build
  options = { max_per_destination: 1, max_total: 5, skip_quotes: true, base_url: "https://www.gbfans.com" }
  html = "<p>#{make_post_text(2_000, rules)}</p>" * 2
  iterations = 200
  elapsed =
    Benchmark.realtime do
      iterations.times do
        doc = Nokogiri::HTML5.fragment(html)
        GbfansAutolink::LinkApplier.apply!(doc, ruleset, options)
      end
    end
  per_apply = elapsed / iterations * 1000
  puts format(
         "full apply! on ~4KB cooked HTML (parse + scan + rewrite): %.3f ms/post (%5.0f posts/sec)",
         per_apply,
         1000 / per_apply,
       )
else
  puts "nokogiri unavailable — skipped full apply! benchmark"
end
