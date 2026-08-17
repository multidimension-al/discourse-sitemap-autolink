# frozen_string_literal: true

RSpec.describe SitemapAutolink::LinkApplier do
  let(:rules) do
    [
      {
        phrase: "widget kit",
        url: "https://example.com/shop/widget-kit",
        type: "product",
        priority: 1,
      },
      { phrase: "gasket set", url: "https://example.com/wiki/gasket-set", type: "wiki", priority: 3 },
      {
        phrase: "deluxe gasket set",
        url: "https://example.com/shop/deluxe-gasket-set",
        type: "category",
        priority: 2,
      },
    ]
  end
  let(:ruleset) { SitemapAutolink::Ruleset.compile(rules) }
  let(:options) { { max_per_destination: 1, max_total: 0, skip_quotes: true } }

  def apply(html, opts = {})
    doc = Nokogiri::HTML5.fragment(html)
    count = described_class.apply!(doc, ruleset, options.merge(opts))
    [doc.to_html, count]
  end

  it "wraps the first occurrence with identifiable markup" do
    html, count = apply("<p>Get a widget kit here. widget kit fans rejoice.</p>")
    expect(count).to eq(1)
    expect(html).to include(
      '<a href="https://example.com/shop/widget-kit" class="sitemap-autolink sitemap-autolink-product" data-sitemap-autolink="true" data-autolink-type="product" data-autolink-term="widget kit">widget kit</a>',
    )
  end

  it "never touches existing links, code, pre or oneboxes" do
    html, count =
      apply(
        '<p><a href="/x">widget kit</a></p><pre>widget kit</pre>' \
          '<code>widget kit</code><aside class="onebox"><p>widget kit</p></aside>',
      )
    expect(count).to eq(0)
    expect(html).not_to include("sitemap-autolink")
  end

  it "skips quotes by default and links them when configured" do
    quoted = '<aside class="quote"><blockquote><p>widget kit</p></blockquote></aside>'
    _html, count = apply(quoted)
    expect(count).to eq(0)
    _html, count = apply(quoted, skip_quotes: false)
    expect(count).to eq(1)
  end

  it "prefers the longest phrase and still links the shorter one elsewhere" do
    html, count = apply("<p>The deluxe gasket set beats a gasket set.</p>")
    expect(count).to eq(2)
    expect(html).to include("/shop/deluxe-gasket-set")
    expect(html).to include("/wiki/gasket-set")
    expect(html).not_to match(/<a[^>]*><a/)
  end

  it "preserves surrounding text and original casing exactly" do
    html, _count = apply("<p>Before WIDGET KIT after.</p>")
    expect(html).to include(">WIDGET KIT</a>")
    expect(html).to include("Before <a")
    expect(html).to include("</a> after.")
  end

  it "keeps entities and attributes intact" do
    html, count = apply('<p title="widget kit">x &amp; widget kit &lt;y&gt;</p>')
    expect(count).to eq(1)
    expect(html).to include('title="widget kit"')
    expect(html).to include("&amp;")
  end

  it "honors the total per-post cap" do
    _html, count = apply("<p>widget kit and a gasket set</p>", max_total: 1)
    expect(count).to eq(1)
  end

  it "counts one allowance per destination across paragraphs" do
    html, count = apply("<p>widget kit</p><p>widget kit</p>")
    expect(count).to eq(1)
    expect(html.scan("sitemap-autolink-product").size).to eq(1)
  end

  it "drops rules with unsafe URL schemes at compile time" do
    unsafe =
      SitemapAutolink::Ruleset.compile(
        [
          { phrase: "widget kit", url: "javascript:alert(1)", type: "product", priority: 1 },
          { phrase: "gasket set", url: "data:text/html,x", type: "wiki", priority: 1 },
          { phrase: "protocol trick", url: "//evil.example/x", type: "wiki", priority: 1 },
          { phrase: "site faq", url: "/faq", type: "manual", priority: 0 },
        ],
      )
    doc = Nokogiri::HTML5.fragment("<p>widget kit, gasket set, protocol trick and the site faq</p>")
    count = described_class.apply!(doc, unsafe, options)
    html = doc.to_html
    expect(count).to eq(1)
    expect(html).not_to include("javascript:")
    expect(html).not_to include("data:")
    expect(html).not_to include("evil.example")
    expect(html).to include('href="/faq"')
  end
end
