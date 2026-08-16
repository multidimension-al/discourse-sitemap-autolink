# frozen_string_literal: true

RSpec.describe SitemapAutolink::SitemapSync do
  let(:base) { "https://example.com" }
  let(:sources) { [{ url: "#{base}/sitemap-products.xml", type: "product" }] }

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

  def build_sync(responses, title_suffixes: [], **opts)
    described_class.new(
      sources: sources,
      title_suffixes: title_suffixes,
      page_fetch_delay_ms: 0,
      http_get: ->(url, _max) { responses[url] },
      **opts,
    )
  end

  it "creates entries with page titles and generated terms on first run" do
    responses = {
      "#{base}/sitemap-products.xml" => sitemap_xml([["/shop/widget-frame-kit", "2026-08-01"]]),
      "#{base}/shop/widget-frame-kit" => page_html("Accessories: Widget Frame Kit"),
    }
    report = build_sync(responses).run!

    expect(report[:added]).to eq(["#{base}/shop/widget-frame-kit"])
    entry = SitemapAutolinkEntry.find_by(url: "#{base}/shop/widget-frame-kit")
    expect(entry.title).to eq("Accessories: Widget Frame Kit")
    expect(entry.title_source).to eq("page")
    expect(entry.terms.linkable.pluck(:normalized_phrase)).to include("widget frame kit")
    expect(report[:phrases_added]).to include("widget frame kit")
    expect(report[:pages_fetched]).to eq(1)
    expect(report[:notes].join).to include("fetched 1 pages")
  end

  it "expands sitemap indexes into their child sitemaps" do
    responses = {
      "#{base}/sitemap.xml" =>
        "<?xml version=\"1.0\"?><sitemapindex><sitemap><loc>#{base}/sitemap-products.xml</loc></sitemap></sitemapindex>",
      "#{base}/sitemap-products.xml" => sitemap_xml([["/shop/widget-frame-kit", nil]]),
      "#{base}/shop/widget-frame-kit" => page_html("Widget Frame Kit"),
    }
    sync =
      described_class.new(
        sources: [{ url: "#{base}/sitemap.xml", type: "product" }],
        title_suffixes: [],
        page_fetch_delay_ms: 0,
        http_get: ->(url, _max) { responses[url] },
      )
    report = sync.run!
    expect(report[:added]).to eq(["#{base}/shop/widget-frame-kit"])
  end

  it "composes suffix fragments split by the | list separator" do
    responses = {
      "#{base}/sitemap-products.xml" => sitemap_xml([["/wiki/martin", nil]]),
      "#{base}/wiki/martin" => page_html("Martin Jarvis - Example Wiki | Example.com"),
    }
    # "- Example Wiki | Example.com" cannot be one list entry, so admins
    # enter the fragments; dangling-connector trimming composes them.
    build_sync(responses, title_suffixes: [" - Example Wiki", "Example.com"]).run!
    entry = SitemapAutolinkEntry.find_by(url: "#{base}/wiki/martin")
    expect(entry.title).to eq("Martin Jarvis")
  end

  it "strips configured title suffixes" do
    responses = {
      "#{base}/sitemap-products.xml" => sitemap_xml([["/shop/widget-frame-kit", nil]]),
      "#{base}/shop/widget-frame-kit" => page_html("Widget Frame Kit - Example Shop"),
    }
    build_sync(responses, title_suffixes: [" - Example Shop"]).run!
    entry = SitemapAutolinkEntry.find_by(url: "#{base}/shop/widget-frame-kit")
    expect(entry.title).to eq("Widget Frame Kit")
  end

  it "does not reprocess unchanged entries" do
    responses = {
      "#{base}/sitemap-products.xml" => sitemap_xml([["/shop/widget-frame-kit", "2026-08-01"]]),
      "#{base}/shop/widget-frame-kit" => page_html("Widget Frame Kit"),
    }
    build_sync(responses).run!

    fetches = []
    sync =
      described_class.new(
        sources: sources,
        title_suffixes: [],
        page_fetch_delay_ms: 0,
        http_get: ->(url, _max) do
          fetches << url
          responses[url]
        end,
      )
    report = sync.run!
    expect(report[:added]).to be_empty
    expect(fetches).to eq(["#{base}/sitemap-products.xml"])
  end

  it "refetches the title when lastmod changes and reports phrase diffs" do
    responses = {
      "#{base}/sitemap-products.xml" => sitemap_xml([["/shop/widget", "2026-08-01"]]),
      "#{base}/shop/widget" => page_html("Widget Alpha"),
    }
    build_sync(responses).run!

    responses["#{base}/sitemap-products.xml"] = sitemap_xml([["/shop/widget", "2026-08-09"]])
    responses["#{base}/shop/widget"] = page_html("Widget Omega")
    report = build_sync(responses).run!

    expect(report[:title_changed]).to eq(["#{base}/shop/widget"])
    entry = SitemapAutolinkEntry.find_by(url: "#{base}/shop/widget")
    expect(entry.title).to eq("Widget Omega")
    expect(report[:phrases_added]).to include("widget omega")
    expect(report[:phrases_removed]).to include("widget alpha")
  end

  it "marks vanished entries removed and reports their phrases" do
    responses = {
      "#{base}/sitemap-products.xml" => sitemap_xml([["/shop/widget", nil]]),
      "#{base}/shop/widget" => page_html("Widget Alpha"),
    }
    build_sync(responses).run!

    responses["#{base}/sitemap-products.xml"] = sitemap_xml([])
    report = build_sync(responses).run!

    expect(report[:removed]).to eq(["#{base}/shop/widget"])
    expect(SitemapAutolinkEntry.find_by(url: "#{base}/shop/widget").removed_from_source).to be(true)
    expect(report[:phrases_removed]).to include("widget alpha")
  end

  it "keeps admin-touched terms across regeneration" do
    responses = {
      "#{base}/sitemap-products.xml" => sitemap_xml([["/shop/widget", "2026-08-01"]]),
      "#{base}/shop/widget" => page_html("Widget Alpha"),
    }
    build_sync(responses).run!
    entry = SitemapAutolinkEntry.find_by(url: "#{base}/shop/widget")
    manual = entry.terms.create!(phrase: "the alpha widget", origin: :manual, state: :approved)

    responses["#{base}/sitemap-products.xml"] = sitemap_xml([["/shop/widget", "2026-08-09"]])
    responses["#{base}/shop/widget"] = page_html("Widget Omega")
    build_sync(responses).run!

    expect(entry.reload.terms.where(id: manual.id)).to exist
  end

  it "handles binary-encoded bodies with typographic characters" do
    responses = {
      "#{base}/sitemap-products.xml" =>
        sitemap_xml([["/shop/spenglers-neutrona-wand", nil]]).b,
      "#{base}/shop/spenglers-neutrona-wand" =>
        page_html("Spengler’s Neutrona Wand").b,
    }
    report = build_sync(responses).run!
    expect(report[:errors]).to be_empty
    entry = SitemapAutolinkEntry.find_by(url: "#{base}/shop/spenglers-neutrona-wand")
    expect(entry.title).to eq("Spengler’s Neutrona Wand")
    expect(entry.terms.linkable.pluck(:normalized_phrase)).to include("spengler's neutrona wand")
  end

  it "falls back to slug titles when the page fetch fails, then heals" do
    responses = {
      "#{base}/sitemap-products.xml" => sitemap_xml([["/shop/foremans-field-guide", nil]]),
      "#{base}/shop/foremans-field-guide" => nil,
    }
    build_sync(responses).run!
    entry = SitemapAutolinkEntry.find_by(url: "#{base}/shop/foremans-field-guide")
    expect(entry.title_source).to eq("slug")
    expect(entry.title).to eq("Foremans Field Guide")

    entry.update_columns(next_title_fetch_at: 1.minute.ago)
    responses["#{base}/shop/foremans-field-guide"] = page_html("Foreman's Field Guide")
    build_sync(responses).run!
    expect(entry.reload.title).to eq("Foreman's Field Guide")
    expect(entry.title_source).to eq("page")
  end

  it "backs off title retries for pages that keep failing instead of taxing every run" do
    responses = {
      "#{base}/sitemap-products.xml" => sitemap_xml([["/wiki/slow-page", nil]]),
      "#{base}/wiki/slow-page" => nil,
    }
    build_sync(responses).run!
    entry = SitemapAutolinkEntry.find_by(url: "#{base}/wiki/slow-page")
    expect(entry.title_source).to eq("slug")
    expect(entry.title_fetch_failures).to eq(1)
    expect(entry.next_title_fetch_at).to be_present

    fetches = []
    report =
      described_class.new(
        sources: sources,
        title_suffixes: [],
        page_fetch_delay_ms: 0,
        http_get: ->(url, _max) do
          fetches << url
          responses[url]
        end,
      ).run!
    expect(fetches).to eq(["#{base}/sitemap-products.xml"])
    expect(report[:notes].join).to include("backoff")

    entry.update_columns(next_title_fetch_at: 1.minute.ago)
    responses["#{base}/wiki/slow-page"] = page_html("Slow Page")
    build_sync(responses).run!
    entry.reload
    expect(entry.title_source).to eq("page")
    expect(entry.title_fetch_failures).to eq(0)
    expect(entry.next_title_fetch_at).to be_nil
  end

  it "persists the heal even when the page title equals the slug title" do
    responses = {
      "#{base}/sitemap-products.xml" => sitemap_xml([["/wiki/martin-jarvis", nil]]),
      "#{base}/wiki/martin-jarvis" => nil,
    }
    build_sync(responses).run!
    entry = SitemapAutolinkEntry.find_by(url: "#{base}/wiki/martin-jarvis")
    expect(entry.title_source).to eq("slug")
    expect(entry.title).to eq("Martin Jarvis")

    entry.update_columns(next_title_fetch_at: 1.minute.ago)
    responses["#{base}/wiki/martin-jarvis"] = page_html("Martin Jarvis")
    build_sync(responses).run!
    expect(entry.reload.title_source).to eq("page")

    fetches = []
    described_class.new(
      sources: sources,
      title_suffixes: [],
      page_fetch_delay_ms: 0,
      http_get: ->(url, _max) do
        fetches << url
        responses[url]
      end,
    ).run!
    expect(fetches).to eq(["#{base}/sitemap-products.xml"])
  end

  it "skips URLs matching excluded patterns and counts them" do
    responses = {
      "#{base}/sitemap-products.xml" =>
        sitemap_xml([["/shop/widget", nil], ["/shop/checkout/basket", nil]]),
      "#{base}/shop/widget" => page_html("Widget Alpha"),
    }
    sync =
      described_class.new(
        sources: sources,
        title_suffixes: [],
        excluded_url_patterns: ["*/checkout*"],
        page_fetch_delay_ms: 0,
        http_get: ->(url, _max) { responses[url] },
      )
    report = sync.run!
    expect(report[:seen]).to eq(1)
    expect(report[:excluded]).to eq(1)
    expect(SitemapAutolinkEntry.find_by(url: "#{base}/shop/checkout/basket")).to be_nil
  end

  it "previews without writing anything" do
    responses = {
      "#{base}/sitemap-products.xml" =>
        sitemap_xml([["/shop/widget-frame-kit", nil], ["/shop/checkout/basket", nil]]),
      "#{base}/shop/widget-frame-kit" => page_html("Widget Frame Kit"),
    }
    sync =
      described_class.new(
        sources: sources,
        title_suffixes: [],
        excluded_url_patterns: ["*/checkout*"],
        page_fetch_delay_ms: 0,
        http_get: ->(url, _max) { responses[url] },
      )
    result = sync.preview(limit_per_source: 5)

    expect(SitemapAutolinkEntry.count).to eq(0)
    source = result[:sources].first
    expect(source[:total_urls]).to eq(2)
    expect(source[:excluded_by_pattern]).to eq(1)
    page = source[:sampled].first
    expect(page[:title]).to eq("Widget Frame Kit")
    expect(page[:phrases].map { |p| p[:phrase] }).to include("Widget Frame Kit")
  end

  it "unescapes backslash-escaped quotes leaking from the source CMS" do
    responses = {
      "#{base}/sitemap-products.xml" => sitemap_xml([["/shop/mattels-figure", nil]]),
      "#{base}/shop/mattels-figure" => page_html("Mattel\\'s 12-Inch Figure"),
    }
    build_sync(responses).run!
    entry = SitemapAutolinkEntry.find_by(url: "#{base}/shop/mattels-figure")
    expect(entry.title).to eq("Mattel's 12-Inch Figure")
  end

  it "re-applies newly configured suffixes to stored titles without refetching pages" do
    responses = {
      "#{base}/sitemap-products.xml" => sitemap_xml([["/shop/widget", "2026-08-01"]]),
      "#{base}/shop/widget" => page_html("Widget Kit - Example Wiki | Example.com"),
    }
    build_sync(responses).run!
    entry = SitemapAutolinkEntry.find_by(url: "#{base}/shop/widget")
    expect(entry.title).to eq("Widget Kit - Example Wiki | Example.com")

    fetches = []
    sync =
      described_class.new(
        sources: sources,
        title_suffixes: [" - Example Wiki", " | Example.com"],
        page_fetch_delay_ms: 0,
        http_get: ->(url, _max) do
          fetches << url
          responses[url]
        end,
      )
    report = sync.run!

    expect(entry.reload.title).to eq("Widget Kit")
    expect(entry.terms.linkable.pluck(:normalized_phrase)).to include("widget kit")
    expect(report[:title_changed]).to include("#{base}/shop/widget")
    expect(fetches).to eq(["#{base}/sitemap-products.xml"])
  end

  it "spaces page fetches by the configured politeness delay" do
    responses = {
      "#{base}/sitemap-products.xml" =>
        sitemap_xml([["/shop/widget-alpha", nil], ["/shop/widget-beta", nil]]),
      "#{base}/shop/widget-alpha" => page_html("Widget Alpha Kit"),
      "#{base}/shop/widget-beta" => page_html("Widget Beta Kit"),
    }
    sync =
      described_class.new(
        sources: sources,
        title_suffixes: [],
        page_fetch_delay_ms: 50,
        http_get: ->(url, _max) { responses[url] },
      )
    expect(sync).to receive(:sleep).with(0.05).twice
    sync.run!
  end

  it "does not mark entries removed when a sitemap fetch errored" do
    responses = {
      "#{base}/sitemap-products.xml" => sitemap_xml([["/shop/widget", nil]]),
      "#{base}/shop/widget" => page_html("Widget Alpha"),
    }
    build_sync(responses).run!

    report = build_sync("#{base}/sitemap-products.xml" => nil).run!
    expect(report[:errors]).not_to be_empty
    expect(SitemapAutolinkEntry.find_by(url: "#{base}/shop/widget").removed_from_source).to be(false)
  end

  it "treats a truncated sitemap as a failed fetch, not a partial URL list" do
    responses = {
      "#{base}/sitemap-products.xml" => sitemap_xml([["/shop/widget", nil]]),
      "#{base}/shop/widget" => page_html("Widget Alpha"),
    }
    build_sync(responses).run!

    truncated = "<?xml version=\"1.0\"?><urlset><url><loc>#{base}/shop/other</loc></url>"
    report = build_sync("#{base}/sitemap-products.xml" => truncated).run!
    expect(report[:errors].join).to include("incomplete")
    expect(report[:seen]).to eq(0)
    expect(SitemapAutolinkEntry.find_by(url: "#{base}/shop/widget").removed_from_source).to be(false)
  end

  it "stops cleanly at the time budget and reports it" do
    responses = {
      "#{base}/sitemap-products.xml" =>
        sitemap_xml([["/shop/widget-alpha", nil], ["/shop/widget-beta", nil]]),
      "#{base}/shop/widget-alpha" => page_html("Widget Alpha Kit"),
      "#{base}/shop/widget-beta" => page_html("Widget Beta Kit"),
    }
    report = build_sync(responses, time_budget_minutes: 0).run!

    expect(report[:partial]).to be(true)
    expect(report[:errors]).to be_empty
    expect(report[:notes].join).to include("time budget")
    expect(report[:seen]).to eq(0)
    expect(SitemapAutolinkEntry.count).to eq(0)
  end

  it "never marks entries removed during a partial run" do
    responses = {
      "#{base}/sitemap-products.xml" => sitemap_xml([["/shop/widget", nil]]),
      "#{base}/shop/widget" => page_html("Widget Alpha"),
    }
    build_sync(responses).run!

    report = build_sync(responses, time_budget_minutes: 0).run!
    expect(report[:partial]).to be(true)
    expect(SitemapAutolinkEntry.find_by(url: "#{base}/shop/widget").removed_from_source).to be(false)
  end

  it "stops cleanly when a cancel is requested mid-run" do
    responses = {
      "#{base}/sitemap-products.xml" =>
        sitemap_xml([["/shop/widget-alpha", nil], ["/shop/widget-beta", nil]]),
      "#{base}/shop/widget-alpha" => page_html("Widget Alpha Kit"),
      "#{base}/shop/widget-beta" => page_html("Widget Beta Kit"),
    }
    sync =
      described_class.new(
        sources: sources,
        title_suffixes: [],
        page_fetch_delay_ms: 0,
        http_get: ->(url, _max) do
          described_class.request_cancel! if url.include?("widget-alpha")
          responses[url]
        end,
      )
    report = sync.run!

    expect(report[:partial]).to be(true)
    expect(report[:notes].join).to include("cancelled")
    expect(report[:seen]).to eq(1)
    expect(SitemapAutolinkEntry.find_by(url: "#{base}/shop/widget-alpha")).to be_present
    expect(SitemapAutolinkEntry.find_by(url: "#{base}/shop/widget-beta")).to be_nil
  ensure
    described_class.clear_cancel!
  end

  it "fetches through internal host rewrites while storing public URLs" do
    stub_request(:get, "http://internal.example:3000/sitemap-products.xml").with(
      headers: {
        "Host" => "example.com",
      },
    ).to_return(body: sitemap_xml([["/shop/widget-frame-kit", nil]]))
    stub_request(:get, "http://internal.example:3000/shop/widget-frame-kit").with(
      headers: {
        "Host" => "example.com",
      },
    ).to_return(body: page_html("Widget Frame Kit"))

    sync =
      described_class.new(
        sources: sources,
        title_suffixes: [],
        page_fetch_delay_ms: 0,
        fetch_host_rewrites: ["example.com=http://internal.example:3000"],
      )
    report = sync.run!

    expect(report[:errors]).to be_empty
    entry = SitemapAutolinkEntry.find_by(url: "#{base}/shop/widget-frame-kit")
    expect(entry).to be_present
    expect(entry.title).to eq("Widget Frame Kit")
  end

  it "reports live progress through on_progress" do
    responses = {
      "#{base}/sitemap-products.xml" =>
        sitemap_xml([["/shop/widget-alpha", nil], ["/shop/widget-beta", nil]]),
      "#{base}/shop/widget-alpha" => page_html("Widget Alpha Kit"),
      "#{base}/shop/widget-beta" => page_html("Widget Beta Kit"),
    }
    progress = []
    build_sync(responses, on_progress: ->(seen) { progress << seen }).run!
    expect(progress).to eq([1, 2])
  end
end
