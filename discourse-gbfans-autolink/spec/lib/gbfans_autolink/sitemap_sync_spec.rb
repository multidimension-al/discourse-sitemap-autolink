# frozen_string_literal: true

RSpec.describe GbfansAutolink::SitemapSync do
  let(:base) { "https://www.gbfans.com" }
  let(:sources) { [{ path: "/sitemaps/shop-products.xml", type: "product" }] }

  def sitemap_xml(entries)
    urls =
      entries
        .map do |(loc, lastmod)|
          "<url><loc>#{base}#{loc}</loc>#{lastmod ? "<lastmod>#{lastmod}</lastmod>" : ""}</url>"
        end
        .join
    "<?xml version=\"1.0\"?><urlset>#{urls}</urlset>"
  end

  def page_html(title)
    "<html><head><meta property=\"og:title\" content=\"#{title}\"/></head><body></body></html>"
  end

  def build_sync(responses)
    described_class.new(
      base_url: base,
      sources: sources,
      http_get: ->(url, _max) { responses[url] },
    )
  end

  it "creates entries with page titles and generated terms on first run" do
    responses = {
      "#{base}/sitemaps/shop-products.xml" =>
        sitemap_xml([["/shop/alice-frame-padding", "2026-08-01"]]),
      "#{base}/shop/alice-frame-padding" => page_html("Pack: ALICE Frame Padding"),
    }
    report = build_sync(responses).run!

    expect(report[:added]).to eq(["/shop/alice-frame-padding"])
    entry = GbfansAutolinkEntry.find_by(url: "/shop/alice-frame-padding")
    expect(entry.title).to eq("Pack: ALICE Frame Padding")
    expect(entry.title_source).to eq("page")
    expect(entry.terms.linkable.pluck(:normalized_phrase)).to include("alice frame padding")
    expect(report[:phrases_added]).to include("alice frame padding")
  end

  it "does not reprocess unchanged entries" do
    responses = {
      "#{base}/sitemaps/shop-products.xml" =>
        sitemap_xml([["/shop/alice-frame-padding", "2026-08-01"]]),
      "#{base}/shop/alice-frame-padding" => page_html("Pack: ALICE Frame Padding"),
    }
    build_sync(responses).run!

    fetches = []
    sync =
      described_class.new(
        base_url: base,
        sources: sources,
        http_get: ->(url, _max) do
          fetches << url
          responses[url]
        end,
      )
    report = sync.run!
    expect(report[:added]).to be_empty
    expect(fetches).to eq(["#{base}/sitemaps/shop-products.xml"])
  end

  it "refetches the title when lastmod changes and reports phrase diffs" do
    responses = {
      "#{base}/sitemaps/shop-products.xml" =>
        sitemap_xml([["/shop/widget", "2026-08-01"]]),
      "#{base}/shop/widget" => page_html("Widget Alpha"),
    }
    build_sync(responses).run!

    responses["#{base}/sitemaps/shop-products.xml"] =
      sitemap_xml([["/shop/widget", "2026-08-09"]])
    responses["#{base}/shop/widget"] = page_html("Widget Omega")
    report = build_sync(responses).run!

    expect(report[:title_changed]).to eq(["/shop/widget"])
    entry = GbfansAutolinkEntry.find_by(url: "/shop/widget")
    expect(entry.title).to eq("Widget Omega")
    expect(report[:phrases_added]).to include("widget omega")
    expect(report[:phrases_removed]).to include("widget alpha")
  end

  it "marks vanished entries removed and reports their phrases" do
    responses = {
      "#{base}/sitemaps/shop-products.xml" => sitemap_xml([["/shop/widget", nil]]),
      "#{base}/shop/widget" => page_html("Widget Alpha"),
    }
    build_sync(responses).run!

    responses["#{base}/sitemaps/shop-products.xml"] = sitemap_xml([])
    report = build_sync(responses).run!

    expect(report[:removed]).to eq(["/shop/widget"])
    expect(GbfansAutolinkEntry.find_by(url: "/shop/widget").removed_from_source).to be(true)
    expect(report[:phrases_removed]).to include("widget alpha")
  end

  it "keeps admin-touched terms across regeneration" do
    responses = {
      "#{base}/sitemaps/shop-products.xml" =>
        sitemap_xml([["/shop/widget", "2026-08-01"]]),
      "#{base}/shop/widget" => page_html("Widget Alpha"),
    }
    build_sync(responses).run!
    entry = GbfansAutolinkEntry.find_by(url: "/shop/widget")
    manual = entry.terms.create!(phrase: "the alpha widget", origin: :manual, state: :approved)

    responses["#{base}/sitemaps/shop-products.xml"] =
      sitemap_xml([["/shop/widget", "2026-08-09"]])
    responses["#{base}/shop/widget"] = page_html("Widget Omega")
    build_sync(responses).run!

    expect(entry.reload.terms.where(id: manual.id)).to exist
  end

  it "falls back to slug titles when the page fetch fails, then heals" do
    responses = {
      "#{base}/sitemaps/shop-products.xml" => sitemap_xml([["/shop/tobins-spirit-guide", nil]]),
      "#{base}/shop/tobins-spirit-guide" => nil,
    }
    build_sync(responses).run!
    entry = GbfansAutolinkEntry.find_by(url: "/shop/tobins-spirit-guide")
    expect(entry.title_source).to eq("slug")
    expect(entry.title).to eq("Tobins Spirit Guide")

    responses["#{base}/shop/tobins-spirit-guide"] = page_html("Tobin's Spirit Guide")
    build_sync(responses).run!
    expect(entry.reload.title).to eq("Tobin's Spirit Guide")
    expect(entry.title_source).to eq("page")
  end

  it "does not mark entries removed when a sitemap fetch errored" do
    responses = {
      "#{base}/sitemaps/shop-products.xml" => sitemap_xml([["/shop/widget", nil]]),
      "#{base}/shop/widget" => page_html("Widget Alpha"),
    }
    build_sync(responses).run!

    report = build_sync("#{base}/sitemaps/shop-products.xml" => nil).run!
    expect(report[:errors]).not_to be_empty
    expect(GbfansAutolinkEntry.find_by(url: "/shop/widget").removed_from_source).to be(false)
  end
end
