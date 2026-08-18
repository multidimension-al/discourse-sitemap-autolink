# frozen_string_literal: true

# One sitemap document the plugin knows about: either a source the admin
# configured, or a child discovered inside a <sitemapindex>.
#
# The status is the import decision. A configured source is `enabled` by
# definition — typing it into the setting IS the opt-in. A child found
# inside an index starts `pending`: it is recorded, counted and shown,
# but none of its URLs are ingested until somebody enables it. That gap
# is the whole point — an index commonly lists children holding tens of
# thousands of URLs that have no business in a link catalog, and the old
# behaviour (expand everything, import everything) gave no chance to
# look first.
class SitemapAutolinkSitemap < ActiveRecord::Base
  ENABLED = "enabled"
  PENDING = "pending"
  IGNORED = "ignored"
  STATUSES = [ENABLED, PENDING, IGNORED].freeze

  INDEX = "index"
  URLSET = "urlset"
  UNKNOWN = "unknown"

  has_many :entry_sitemaps,
           class_name: "SitemapAutolinkEntrySitemap",
           foreign_key: :sitemap_id,
           dependent: :delete_all
  has_many :entries, through: :entry_sitemaps, source: :entry

  validates :url, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  scope :importing, -> { where(status: ENABLED).where.not(kind: INDEX) }
  scope :awaiting_decision, -> { where(status: PENDING) }

  def self.normalize_url(url)
    url.to_s.strip
  end

  def self.valid_status?(value)
    STATUSES.include?(value.to_s)
  end

  def index?
    kind == INDEX
  end

  def importing?
    status == ENABLED && !index?
  end
end
