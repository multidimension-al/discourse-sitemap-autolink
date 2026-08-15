# frozen_string_literal: true

RSpec.describe GbfansAutolink::LinkApplier do
  let(:rules) do
    [
      { phrase: "elbow pads", url: "/shop/grey-elbow-pads", type: "product", priority: 1 },
      { phrase: "proton pack", url: "/wiki/proton-pack", type: "wiki", priority: 3 },
      { phrase: "hasbro proton pack", url: "/shop/hasbro", type: "category", priority: 2 },
    ]
  end
  let(:ruleset) { GbfansAutolink::Ruleset.compile(rules) }
  let(:options) do
    { max_per_destination: 1, max_total: 0, skip_quotes: true, base_url: "https://www.gbfans.com" }
  end

  def apply(html, opts = {})
    doc = Nokogiri::HTML5.fragment(html)
    count = described_class.apply!(doc, ruleset, options.merge(opts))
    [doc.to_html, count]
  end

  it "wraps the first occurrence with identifiable markup" do
    html, count = apply("<p>Get elbow pads here. elbow pads rock.</p>")
    expect(count).to eq(1)
    expect(html).to include(
      '<a href="https://www.gbfans.com/shop/grey-elbow-pads" class="gbfans-autolink gbfans-autolink-product" data-gbfans-autolink="true" data-gbfans-link-type="product" data-gbfans-term="elbow pads">elbow pads</a>',
    )
  end

  it "never touches existing links, code, pre or oneboxes" do
    html, count =
      apply(
        '<p><a href="/x">elbow pads</a></p><pre>elbow pads</pre>' \
          '<code>elbow pads</code><aside class="onebox"><p>elbow pads</p></aside>',
      )
    expect(count).to eq(0)
    expect(html).not_to include("gbfans-autolink")
  end

  it "skips quotes by default and links them when configured" do
    quoted = '<aside class="quote"><blockquote><p>elbow pads</p></blockquote></aside>'
    _html, count = apply(quoted)
    expect(count).to eq(0)
    _html, count = apply(quoted, skip_quotes: false)
    expect(count).to eq(1)
  end

  it "prefers the longest phrase and still links the shorter one elsewhere" do
    html, count = apply("<p>The hasbro proton pack beats a proton pack.</p>")
    expect(count).to eq(2)
    expect(html).to include("/shop/hasbro")
    expect(html).to include("/wiki/proton-pack")
    expect(html).not_to match(/<a[^>]*><a/)
  end

  it "preserves surrounding text and original casing exactly" do
    html, _count = apply("<p>Before ELBOW PADS after.</p>")
    expect(html).to include(">ELBOW PADS</a>")
    expect(html).to include("Before <a")
    expect(html).to include("</a> after.")
  end

  it "keeps entities and attributes intact" do
    html, count = apply('<p title="elbow pads">x &amp; elbow pads &lt;y&gt;</p>')
    expect(count).to eq(1)
    expect(html).to include('title="elbow pads"')
    expect(html).to include("&amp;")
  end

  it "honors the total per-post cap" do
    _html, count = apply("<p>elbow pads and a proton pack</p>", max_total: 1)
    expect(count).to eq(1)
  end

  it "counts one allowance per destination across paragraphs" do
    html, count = apply("<p>elbow pads</p><p>elbow pads</p>")
    expect(count).to eq(1)
    expect(html.scan("gbfans-autolink-product").size).to eq(1)
  end
end
