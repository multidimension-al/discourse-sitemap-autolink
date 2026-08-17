# frozen_string_literal: true

RSpec.describe Jobs::SitemapAutolinkRebakePosts do
  fab!(:matching) { Fabricate(:post, raw: "I finished my Widget Frame Kit yesterday") }
  fab!(:matching_twice) { Fabricate(:post, raw: "carry case AND a widget frame kit together") }
  fab!(:unrelated) { Fabricate(:post, raw: "nothing relevant in this one") }

  def rebaked_ids(&blk)
    ids = []
    allow_any_instance_of(Post).to receive(:rebake!) { |post, **| ids << post.id }
    blk.call
    ids
  end

  it "rebakes each candidate post exactly once, even when several phrases match it" do
    ids =
      rebaked_ids do
        described_class.new.execute(phrases: ["widget frame kit", "carry case"])
      end
    expect(ids).to contain_exactly(matching.id, matching_twice.id)
  end

  # Catalog phrases are normalized to a straight apostrophe; posts keep
  # whatever the member typed. Such a post gets its link at cook time, so
  # the candidate filter has to be able to find it.
  it "finds posts that spell a phrase with a typographic apostrophe" do
    curly = Fabricate(:post, raw: "I keep Foreman’s Field Guide on the bench")
    ids = rebaked_ids { described_class.new.execute(phrases: ["foreman's field guide"]) }
    expect(ids).to eq([curly.id])
  end

  it "ignores blank and too-short phrases" do
    ids = rebaked_ids { described_class.new.execute(phrases: ["", "  ", "ab"]) }
    expect(ids).to be_empty
  end

  it "stops at the max_posts wave cap without re-enqueueing" do
    ids =
      rebaked_ids do
        described_class.new.execute(phrases: ["widget frame kit"], max_posts: 1)
      end
    expect(ids.size).to eq(1)
    expect(described_class.jobs.size).to eq(0)
  end

  it "continues a large wave in a follow-up job carrying the remaining budget" do
    allow(SiteSetting).to receive(:sitemap_autolink_max_rebakes_per_job_run).and_return(1)
    ids =
      rebaked_ids do
        described_class.new.execute(phrases: ["widget frame kit"], max_posts: 5)
      end
    expect(ids).to eq([matching.id])

    followup = described_class.jobs.last
    expect(followup).to be_present
    args = followup["args"].first
    expect(args["phrases"]).to eq(["widget frame kit"])
    expect(args["after_id"]).to eq(matching.id)
    expect(args["max_posts"]).to eq(4)
  end

  it "derives the phrase list from the active catalog in all_phrases mode" do
    entry =
      SitemapAutolinkEntry.create!(
        url: "https://example.com/shop/widget-frame-kit",
        title: "Widget Frame Kit",
        content_type: "product",
      )
    entry.terms.create!(phrase: "widget frame kit", origin: :generated, state: :auto_active)
    allow(SiteSetting).to receive(:sitemap_autolink_max_rebakes_per_job_run).and_return(1)

    ids = rebaked_ids { described_class.new.execute(all_phrases: true) }
    expect(ids).to eq([matching.id])

    followup = described_class.jobs.last["args"].first
    expect(followup["all_phrases"]).to eq(true)
    expect(followup["phrases"]).to be_nil
  end

  it "resumes after after_id" do
    ids =
      rebaked_ids do
        described_class.new.execute(phrases: ["widget frame kit"], after_id: matching.id)
      end
    expect(ids).to eq([matching_twice.id])
  end
end

RSpec.describe Jobs::SitemapAutolinkSelectiveRebake do
  fab!(:post) { Fabricate(:post, raw: "a Widget Frame Kit post") }

  it "is a no-op tombstone: drains stale queued jobs without rebaking" do
    expect_any_instance_of(Post).not_to receive(:rebake!)
    described_class.new.execute(phrase: "widget frame kit")
  end
end
