# frozen_string_literal: true

RSpec.describe Jobs::SitemapAutolinkSync do
  let(:report) do
    {
      seen: 12,
      excluded: 3,
      added: %w[a b],
      title_changed: ["c"],
      removed: [],
      restored: [],
      phrases_added: %w[p1 p2],
      phrases_removed: [],
      errors: [],
      sources: ["https://example.com/sitemap.xml (product)"],
    }
  end

  before do
    SiteSetting.sitemap_autolink_enabled = true
    SiteSetting.sitemap_autolink_sync_enabled = true
    SiteSetting.sitemap_autolink_sources = "https://example.com/sitemap.xml,product"
    allow(SitemapAutolink::SitemapSync).to receive(:new).and_return(
      instance_double(SitemapAutolink::SitemapSync, run!: report),
    )
  end

  it "records a durable sync run with the report's numbers" do
    expect { described_class.new.execute(triggered_by: "manual") }.to change {
      SitemapAutolinkSyncRun.count
    }.by(1)

    run = SitemapAutolinkSyncRun.recent.first
    expect(run.success).to be(true)
    expect(run.triggered_by).to eq("manual")
    expect(run.urls_seen).to eq(12)
    expect(run.urls_excluded).to eq(3)
    expect(run.entries_added).to eq(2)
    expect(run.entries_retitled).to eq(1)
    expect(run.phrases_added).to eq(2)
    expect(run.finished_at).to be_present
    expect(run.sources).to include("example.com")
  end

  it "records a time-budget stop as successful-but-partial, not failed" do
    report[:partial] = true
    report[:notes] = ["stopped at the 30-minute time budget after 12 URLs"]
    described_class.new.execute(triggered_by: "manual")

    run = SitemapAutolinkSyncRun.recent.first
    expect(run.success).to be(true)
    expect(run.partial).to be(true)
    expect(run.error_details).to include("time budget")
  end

  it "records failures with error details" do
    report[:errors] << "failed to fetch sitemap https://example.com/sitemap.xml"
    described_class.new.execute({})
    run = SitemapAutolinkSyncRun.recent.first
    expect(run.success).to be(false)
    expect(run.error_details).to include("failed to fetch")
  end

  it "skips while an admin cancel is in effect or another sync holds the lock" do
    SitemapAutolink::SitemapSync.request_cancel!
    expect { described_class.new.execute(triggered_by: "manual") }.not_to change {
      SitemapAutolinkSyncRun.count
    }
    SitemapAutolink::SitemapSync.clear_cancel!

    Discourse.redis.set(SitemapAutolink::SitemapSync::RUNNING_LOCK_KEY, "1")
    expect { described_class.new.execute(triggered_by: "manual") }.not_to change {
      SitemapAutolinkSyncRun.count
    }
  ensure
    SitemapAutolink::SitemapSync.clear_cancel!
    Discourse.redis.del(SitemapAutolink::SitemapSync::RUNNING_LOCK_KEY)
  end

  it "releases the running lock when the sync finishes" do
    described_class.new.execute(triggered_by: "manual")
    expect(Discourse.redis.get(SitemapAutolink::SitemapSync::RUNNING_LOCK_KEY)).to be_nil
  end

  it "does not run on schedule when sync is disabled, but manual trigger works" do
    SiteSetting.sitemap_autolink_sync_enabled = false
    expect { described_class.new.execute({}) }.not_to change { SitemapAutolinkSyncRun.count }
    expect { described_class.new.execute(triggered_by: "manual") }.to change {
      SitemapAutolinkSyncRun.count
    }.by(1)
  end

  it "enqueues ONE batched rebake job for all phrase changes when enabled" do
    SiteSetting.sitemap_autolink_auto_rebake_on_changes = true
    SiteSetting.sitemap_autolink_auto_rebake_max_posts = 500
    expect_enqueued_with(
      job: :sitemap_autolink_rebake_posts,
      args: {
        phrases: %w[p1 p2],
        max_posts: 500,
      },
    ) { described_class.new.execute({}) }
  end

  it "does not enqueue per-phrase jobs" do
    SiteSetting.sitemap_autolink_auto_rebake_on_changes = true
    described_class.new.execute({})
    expect(
      Jobs::SitemapAutolinkSelectiveRebake.jobs.size,
    ).to eq(0)
  end

  it "skips auto-rebake entirely for catalog-scale phrase changes" do
    SiteSetting.sitemap_autolink_auto_rebake_on_changes = true
    SiteSetting.sitemap_autolink_auto_rebake_max_phrases = 3
    report[:phrases_added] = %w[p1 p2 p3 p4]
    described_class.new.execute({})
    expect(Jobs::SitemapAutolinkRebakePosts.jobs.size).to eq(0)
  end

  it "labels stale unfinished runs as interrupted instead of leaving them unexplained" do
    orphan =
      SitemapAutolinkSyncRun.create!(started_at: 3.hours.ago, triggered_by: "manual")
    fresh =
      SitemapAutolinkSyncRun.create!(started_at: 5.minutes.ago, triggered_by: "manual")

    described_class.new.execute(triggered_by: "manual")

    expect(orphan.reload.success).to be(false)
    expect(orphan.error_details).to include("interrupted")
    expect(fresh.reload.error_details).to be_nil
  end

  it "does not enqueue a rebake job when nothing changed" do
    SiteSetting.sitemap_autolink_auto_rebake_on_changes = true
    report[:phrases_added] = []
    described_class.new.execute({})
    expect(Jobs::SitemapAutolinkRebakePosts.jobs.size).to eq(0)
  end
end
