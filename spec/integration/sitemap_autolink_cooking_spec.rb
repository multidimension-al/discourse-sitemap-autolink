# frozen_string_literal: true

# The core behavioral contract, exercised through Discourse's REAL
# pipelines (PostCreator, PostRevisor, Post#rebake!): raw stays
# untouched, cooked gains reversible links.
RSpec.describe "Sitemap autolink cooking pipeline" do
  # Without the auto groups a fabricated user is in no trust-level
  # group, and the group-based permission settings refuse the topic.
  fab!(:user) { Fabricate(:user, refresh_auto_groups: true) }

  before do
    Jobs.run_immediately!
    SitemapAutolink::Catalog.reset_cache!
    SiteSetting.sitemap_autolink_enabled = true
    SiteSetting.sitemap_autolink_manual_mappings =
      "widget kit,https://example.com/shop/widget-kit,product|gasket set,https://example.com/shop/gasket-set,product"
  end

  def autolinks(post)
    Nokogiri::HTML5.fragment(post.reload.cooked).css("a[data-sitemap-autolink]")
  end

  describe "basic linking" do
    it "links only the first occurrence on post creation and never modifies raw" do
      raw = "I bought a widget kit. This widget kit is great."
      post = create_post(raw: raw, user: user)

      expect(post.reload.raw).to eq(raw)
      links = autolinks(post)
      expect(links.size).to eq(1)
      expect(links.first["href"]).to eq("https://example.com/shop/widget-kit")
      expect(links.first["class"]).to eq("sitemap-autolink sitemap-autolink-product")
      expect(links.first.text).to eq("widget kit")
      expect(post.cooked).to match(%r{bought a <a[^>]*sitemap-autolink})
    end

    it "gives each post its own allowance" do
      first = create_post(raw: "Fresh widget kit here", user: user)
      second = create_post(raw: "My widget kit too", topic_id: first.topic_id, user: user)
      expect(autolinks(first).size).to eq(1)
      expect(autolinks(second).size).to eq(1)
    end

    it "links different destinations in the same post" do
      post = create_post(raw: "I bought a widget kit and a gasket set today", user: user)
      expect(autolinks(post).map { |a| a["href"] }).to contain_exactly(
        "https://example.com/shop/widget-kit",
        "https://example.com/shop/gasket-set",
      )
    end

    it "honors the configurable total per-post cap" do
      SiteSetting.sitemap_autolink_max_links_per_post = 1
      post = create_post(raw: "A widget kit and a gasket set", user: user)
      expect(autolinks(post).size).to eq(1)
    end

    it "leaves quotes, code and manually authored links untouched" do
      raw = <<~MD
        [quote]
        widget kit
        [/quote]

        `widget kit` and [widget kit](https://example.org/manual)

        real widget kit
      MD
      post = create_post(raw: raw, user: user)
      links = autolinks(post)
      expect(links.size).to eq(1)
      expect(post.cooked).to include('href="https://example.org/manual"')
      quote_html = Nokogiri::HTML5.fragment(post.cooked).css("aside.quote").to_html
      expect(quote_html).not_to include("sitemap-autolink")
    end

    it "applies current rules when a post is edited" do
      post = create_post(raw: "Nothing to link here", user: user)
      expect(autolinks(post)).to be_empty

      PostRevisor.new(post).revise!(user, raw: "Now with a widget kit!")
      expect(autolinks(post).size).to eq(1)
      expect(post.reload.raw).to eq("Now with a widget kit!")
    end
  end

  describe "rebaking (reversibility)" do
    it "applies newly added mappings to historical posts on rebake" do
      SiteSetting.sitemap_autolink_manual_mappings = ""
      post = create_post(raw: "Old post about a widget kit", user: user)
      expect(autolinks(post)).to be_empty

      SiteSetting.sitemap_autolink_manual_mappings =
        "widget kit,https://example.com/shop/widget-kit,product"
      post.rebake!
      expect(autolinks(post).size).to eq(1)
    end

    it "removes generated links when the mapping is removed, leaving raw intact" do
      raw = "Discussing the widget kit at length"
      post = create_post(raw: raw, user: user)
      expect(autolinks(post).size).to eq(1)

      SiteSetting.sitemap_autolink_manual_mappings = ""
      post.rebake!
      expect(autolinks(post)).to be_empty
      expect(post.reload.raw).to eq(raw)
      expect(post.cooked).to include("widget kit")
    end

    it "retargets links when the destination changes" do
      post = create_post(raw: "Get a widget kit now", user: user)
      expect(autolinks(post).first["href"]).to include("/shop/widget-kit")

      SiteSetting.sitemap_autolink_manual_mappings =
        "widget kit,https://example.com/shop/widget-kit-v2,product"
      post.rebake!
      expect(autolinks(post).first["href"]).to include("/shop/widget-kit-v2")
    end

    it "does nothing when the plugin is disabled" do
      post = create_post(raw: "Some widget kit", user: user)
      expect(autolinks(post).size).to eq(1)

      SiteSetting.sitemap_autolink_enabled = false
      post.rebake!
      expect(autolinks(post)).to be_empty
    end
  end

  describe "category exclusions (marketplace areas)" do
    fab!(:sale_category, :category)
    fab!(:sale_subcategory) { Fabricate(:category, parent_category_id: sale_category.id) }
    fab!(:normal_category, :category)

    before { SiteSetting.sitemap_autolink_excluded_categories = sale_category.id.to_s }

    it "never links posts in an excluded category" do
      post = create_post(raw: "Selling my widget kit, barely used", category: sale_category, user: user)
      expect(autolinks(post)).to be_empty
    end

    it "excludes subcategories of an excluded category" do
      post = create_post(raw: "Selling a widget kit cheap", category: sale_subcategory, user: user)
      expect(autolinks(post)).to be_empty
    end

    it "still links in other categories" do
      post = create_post(raw: "Comparing widget kit brands", category: normal_category, user: user)
      expect(autolinks(post).size).to eq(1)
    end

    it "links again after the exclusion is lifted and the post is rebaked" do
      post = create_post(raw: "Selling a widget kit", category: sale_category, user: user)
      expect(autolinks(post)).to be_empty

      SiteSetting.sitemap_autolink_excluded_categories = ""
      post.rebake!
      expect(autolinks(post).size).to eq(1)
    end
  end

  describe "database catalog entries" do
    fab!(:entry) do
      SitemapAutolinkEntry.create!(
        url: "https://example.com/shop/gasket-set",
        title: "Accessories: Gasket Set",
        content_type: "product",
        source: "manual",
        title_source: "manual",
        auto_discovered: false,
      )
    end

    before do
      SiteSetting.sitemap_autolink_manual_mappings = ""
      entry.terms.create!(phrase: "gasket set", origin: :manual, state: :approved)
      SitemapAutolink::Catalog.bump_version!
    end

    it "links from catalog terms with the entry id in the markup" do
      post = create_post(raw: "Ordered a gasket set yesterday", user: user)
      links = autolinks(post)
      expect(links.size).to eq(1)
      expect(links.first["data-autolink-id"]).to eq(entry.id.to_s)
      expect(links.first["href"]).to eq("https://example.com/shop/gasket-set")
    end

    it "matches typographic apostrophes in posts" do
      entry2 =
        SitemapAutolinkEntry.create!(
          url: "https://example.com/wiki/foremans-field-guide",
          title: "Foreman's Field Guide",
          content_type: "wiki",
          source: "manual",
          title_source: "manual",
          auto_discovered: false,
        )
      entry2.terms.create!(phrase: "Foreman's Field Guide", origin: :manual, state: :approved)
      SitemapAutolink::Catalog.bump_version!

      post = create_post(raw: "Check Foreman’s Field Guide", user: user)
      expect(autolinks(post).size).to eq(1)
      expect(post.cooked).to include("Foreman’s Field Guide</a>")
    end

    it "disabling an entry and rebaking removes its links" do
      post = create_post(raw: "Ordered a gasket set", user: user)
      expect(autolinks(post).size).to eq(1)

      entry.update!(enabled: false)
      SitemapAutolink::Catalog.bump_version!
      post.rebake!
      expect(autolinks(post)).to be_empty
    end

    it "pending_review terms never link until approved" do
      entry.terms.create!(
        phrase: "gasket set deluxe",
        origin: :generated,
        state: :pending_review,
      )
      SitemapAutolink::Catalog.bump_version!
      post = create_post(raw: "A gasket set deluxe appears", user: user)
      # only the approved "gasket set" phrase inside it may link
      expect(autolinks(post).map { |a| a["data-autolink-term"] }).to eq(["gasket set"])
    end

    it "restricting enabled types keeps other types dark until listed" do
      wiki =
        SitemapAutolinkEntry.create!(
          url: "https://example.com/wiki/widget-lore",
          title: "Widget Lore Compendium",
          content_type: "wiki",
          source: "manual",
          title_source: "manual",
          auto_discovered: false,
        )
      wiki.terms.create!(phrase: "Widget Lore Compendium", origin: :manual, state: :approved)
      SiteSetting.sitemap_autolink_enabled_types = "product"
      SitemapAutolink::Catalog.bump_version!

      post = create_post(raw: "The Widget Lore Compendium returns", user: user)
      expect(autolinks(post)).to be_empty

      SiteSetting.sitemap_autolink_enabled_types = "product|wiki"
      post.rebake!
      expect(autolinks(post).size).to eq(1)
      expect(autolinks(post).first["class"]).to include("sitemap-autolink-wiki")
    end
  end
end
