# frozen_string_literal: true

RSpec.describe SitemapAutolink::UrlFilter do
  def excluded?(url, patterns)
    described_class.excluded?(url, described_class.compile(patterns))
  end

  it "matches plain patterns as substrings, case-insensitively" do
    expect(excluded?("https://example.com/wiki/Uncategorized/page", ["/uncategorized/"])).to be(true)
    expect(excluded?("https://example.com/wiki/props/page", ["/uncategorized/"])).to be(false)
  end

  it "supports * wildcards" do
    expect(excluded?("https://example.com/shop/checkout/step-1", ["*/checkout*"])).to be(true)
    expect(excluded?("https://example.com/tag/anything", ["https://example.com/tag/*"])).to be(true)
    expect(excluded?("https://example.com/shop/widget", ["*/checkout*"])).to be(false)
  end

  it "treats regex metacharacters in patterns literally" do
    expect(excluded?("https://example.com/a.b/page", ["/a.b/"])).to be(true)
    expect(excluded?("https://example.com/axb/page", ["/a.b/"])).to be(false)
  end

  it "ignores blank patterns" do
    expect(described_class.compile(["", "  "])).to eq([])
    expect(excluded?("https://example.com/x", ["", "  "])).to be(false)
  end
end
