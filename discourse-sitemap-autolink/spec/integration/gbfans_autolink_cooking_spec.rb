# frozen_string_literal: true

# The proof-of-concept contract from the migration plan, exercised
# through Discourse's REAL pipelines (PostCreator, PostRevisor,
# Post#rebake!): raw stays untouched, cooked gains reversible links.
RSpec.describe "GBFans autolink cooking pipeline" do
  fab!(:user)

  before do
    Jobs.run_immediately!
    GbfansAutolink::Catalog.reset_cache!
    SiteSetting.gbfans_autolink_enabled = true
    SiteSetting.gbfans_autolink_test_mappings =
      "elbow pads,/shop/grey-elbow-pads,product|Alice frame padding,/shop/alice-frame-padding,product"
  end

  def autolinks(post)
    Nokogiri::HTML5.fragment(post.reload.cooked).css("a[data-gbfans-autolink]")
  end

  describe "proof of concept: elbow pads -> shop URL" do
    it "links only the first occurrence on post creation and never modifies raw" do
      raw = "I bought some elbow pads. These elbow pads are great."
      post = create_post(raw: raw, user: user)

      expect(post.reload.raw).to eq(raw)
      links = autolinks(post)
      expect(links.size).to eq(1)
      expect(links.first["href"]).to eq("https://www.gbfans.com/shop/grey-elbow-pads")
      expect(links.first["class"]).to eq("gbfans-autolink gbfans-autolink-product")
      expect(links.first.text).to eq("elbow pads")
      expect(post.cooked).to match(%r{bought some <a[^>]*gbfans-autolink})
    end

    it "gives each post its own allowance" do
      first = create_post(raw: "Fresh elbow pads here", user: user)
      second = create_post(raw: "My elbow pads too", topic_id: first.topic_id, user: user)
      expect(autolinks(first).size).to eq(1)
      expect(autolinks(second).size).to eq(1)
    end

    it "links different destinations in the same post" do
      post = create_post(raw: "I bought elbow pads and Alice frame padding today", user: user)
      expect(autolinks(post).map { |a| a["href"] }).to contain_exactly(
        "https://www.gbfans.com/shop/grey-elbow-pads",
        "https://www.gbfans.com/shop/alice-frame-padding",
      )
    end

    it "honors the configurable total per-post cap" do
      SiteSetting.gbfans_autolink_max_links_per_post = 1
      post = create_post(raw: "Some elbow pads and Alice frame padding", user: user)
      expect(autolinks(post).size).to eq(1)
    end

    it "leaves quotes, code and manually authored links untouched" do
      raw = <<~MD
        [quote]
        elbow pads
        [/quote]

        `elbow pads` and [elbow pads](https://example.com/manual)

        real elbow pads
      MD
      post = create_post(raw: raw, user: user)
      links = autolinks(post)
      expect(links.size).to eq(1)
      expect(post.cooked).to include('href="https://example.com/manual"')
      quote_html = Nokogiri::HTML5.fragment(post.cooked).css("aside.quote").to_html
      expect(quote_html).not_to include("gbfans-autolink")
    end

    it "applies current rules when a post is edited" do
      post = create_post(raw: "Nothing to link here", user: user)
      expect(autolinks(post)).to be_empty

      PostRevisor.new(post).revise!(user, raw: "Now with elbow pads!")
      expect(autolinks(post).size).to eq(1)
      expect(post.reload.raw).to eq("Now with elbow pads!")
    end
  end

  describe "rebaking (reversibility)" do
    it "applies newly added mappings to historical posts on rebake" do
      SiteSetting.gbfans_autolink_test_mappings = ""
      post = create_post(raw: "Old post about elbow pads", user: user)
      expect(autolinks(post)).to be_empty

      SiteSetting.gbfans_autolink_test_mappings = "elbow pads,/shop/grey-elbow-pads,product"
      post.rebake!
      expect(autolinks(post).size).to eq(1)
    end

    it "removes generated links when the mapping is removed, leaving raw intact" do
      raw = "Discussing elbow pads at length"
      post = create_post(raw: raw, user: user)
      expect(autolinks(post).size).to eq(1)

      SiteSetting.gbfans_autolink_test_mappings = ""
      post.rebake!
      expect(autolinks(post)).to be_empty
      expect(post.reload.raw).to eq(raw)
      expect(post.cooked).to include("elbow pads")
    end

    it "retargets links when the destination changes" do
      post = create_post(raw: "Get elbow pads now", user: user)
      expect(autolinks(post).first["href"]).to include("/shop/grey-elbow-pads")

      SiteSetting.gbfans_autolink_test_mappings = "elbow pads,/shop/new-elbow-pads,product"
      post.rebake!
      expect(autolinks(post).first["href"]).to include("/shop/new-elbow-pads")
    end

    it "does nothing when the plugin is disabled" do
      post = create_post(raw: "Some elbow pads", user: user)
      expect(autolinks(post).size).to eq(1)

      SiteSetting.gbfans_autolink_enabled = false
      post.rebake!
      expect(autolinks(post)).to be_empty
    end
  end

  describe "database catalog entries" do
    fab!(:entry) do
      GbfansAutolinkEntry.create!(
        url: "/shop/alice-frame-padding",
        title: "Pack: ALICE Frame Padding",
        content_type: "product",
        source: "manual",
        title_source: "manual",
        auto_discovered: false,
      )
    end

    before do
      SiteSetting.gbfans_autolink_test_mappings = ""
      entry.terms.create!(phrase: "ALICE frame padding", origin: :manual, state: :approved)
      GbfansAutolink::Catalog.bump_version!
    end

    it "links from catalog terms with the entry id in the markup" do
      post = create_post(raw: "Ordered ALICE frame padding yesterday", user: user)
      links = autolinks(post)
      expect(links.size).to eq(1)
      expect(links.first["data-gbfans-link-id"]).to eq(entry.id.to_s)
      expect(links.first["href"]).to eq("https://www.gbfans.com/shop/alice-frame-padding")
    end

    it "matches typographic variants in posts" do
      entry.terms.create!(phrase: "Tobin's Spirit Guide", origin: :manual, state: :approved)
      entry2 =
        GbfansAutolinkEntry.create!(
          url: "/shop/tobins-spirit-guide",
          title: "Tobin's Spirit Guide",
          content_type: "product",
          source: "manual",
          title_source: "manual",
          auto_discovered: false,
        )
      entry2.terms.create!(phrase: "Tobin's Spirit Guide", origin: :manual, state: :approved)
      GbfansAutolink::Catalog.bump_version!

      post = create_post(raw: "Check Tobin’s Spirit Guide", user: user)
      expect(autolinks(post).size).to eq(1)
      expect(post.cooked).to include("Tobin’s Spirit Guide</a>")
    end

    it "disabling an entry and rebaking removes its links" do
      post = create_post(raw: "Ordered ALICE frame padding", user: user)
      expect(autolinks(post).size).to eq(1)

      entry.update!(enabled: false)
      GbfansAutolink::Catalog.bump_version!
      post.rebake!
      expect(autolinks(post)).to be_empty
    end

    it "pending_review terms never link until approved" do
      entry.terms.create!(
        phrase: "frame padding kit",
        origin: :generated,
        state: :pending_review,
      )
      GbfansAutolink::Catalog.bump_version!
      post = create_post(raw: "A frame padding kit appears", user: user)
      expect(autolinks(post)).to be_empty
    end

    it "wiki type stays dark until enabled in gbfans_autolink_enabled_types" do
      wiki =
        GbfansAutolinkEntry.create!(
          url: "/wiki/characters/vigo-the-carpathian",
          title: "Vigo the Carpathian",
          content_type: "wiki",
          source: "manual",
          title_source: "manual",
          auto_discovered: false,
        )
      wiki.terms.create!(phrase: "Vigo the Carpathian", origin: :manual, state: :approved)
      GbfansAutolink::Catalog.bump_version!

      post = create_post(raw: "Vigo the Carpathian returns", user: user)
      expect(autolinks(post)).to be_empty

      SiteSetting.gbfans_autolink_enabled_types = "manual|product|category|wiki"
      post.rebake!
      expect(autolinks(post).size).to eq(1)
      expect(autolinks(post).first["class"]).to include("gbfans-autolink-wiki")
    end
  end
end
