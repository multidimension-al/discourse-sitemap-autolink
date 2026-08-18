# frozen_string_literal: true

# The compiled ruleset the linking hook consumes. These cover the two
# promises the catalog makes about MANUAL aliases, both of which turn on
# reading the `origin` enum correctly — and both of which fail silently
# if it is read wrong, because a manual alias that is mistaken for a
# generated one still compiles, just with the wrong gate and the wrong
# rank.
RSpec.describe SitemapAutolink::Catalog do
  fab!(:manual_page) do
    # Deliberately sorts AFTER the other page. Collisions are broken by
    # priority first and only then by URL, so a page that would lose an
    # alphabetical tie-break proves it won on rank.
    SitemapAutolinkEntry.create!(
      url: "https://example.com/zz-manual",
      title: "Widget Frame Kit",
      content_type: "product",
      source: "sitemap",
    )
  end

  fab!(:generated_page) do
    SitemapAutolinkEntry.create!(
      url: "https://example.com/aa-generated",
      title: "Widget Frame Kit",
      content_type: "product",
      source: "sitemap",
    )
  end

  before do
    SiteSetting.sitemap_autolink_enabled = true
    described_class.reset_cache!
    described_class.bump_version!
  end

  it "lets a manual alias through the excluded-terms list, but not a generated phrase" do
    SiteSetting.sitemap_autolink_excluded_terms = "widget kit|gasket set"
    manual_page.terms.create!(phrase: "Widget Kit", origin: :manual, state: :approved)
    generated_page.terms.create!(phrase: "Gasket Set", origin: :generated, state: :auto_active)
    described_class.reset_cache!

    phrases = described_class.ruleset.rules.map { |r| r[:phrase] }
    expect(phrases).to include("widget kit")
    expect(phrases).not_to include("gasket set")
  end

  it "ranks a manual alias above a generated phrase claiming the same words" do
    manual_page.terms.create!(phrase: "Widget Frame Kit", origin: :manual, state: :approved)
    generated_page.terms.create!(
      phrase: "Widget Frame Kit",
      origin: :generated,
      state: :auto_active,
    )
    described_class.reset_cache!

    rule = described_class.ruleset.rules.find { |r| r[:phrase] == "widget frame kit" }
    expect(rule[:url]).to eq(manual_page.url)
  end
end
