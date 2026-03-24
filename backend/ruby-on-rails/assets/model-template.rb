# Active Record Model Template
#
# Includes: associations, validations, scopes, callbacks, enums, encryption.
# Customize and rename for your domain model.
#
# Place in: app/models/<name>.rb

class Article < ApplicationRecord
  # ── Associations ────────────────────────────────────────────────────────────
  belongs_to :author, class_name: "User", counter_cache: true
  belongs_to :category, optional: true

  has_many :comments, dependent: :destroy
  has_many :commenters, through: :comments, source: :user
  has_many :taggings, dependent: :destroy
  has_many :tags, through: :taggings

  has_one :metadata, class_name: "ArticleMetadata", dependent: :destroy

  has_one_attached  :cover_image
  has_many_attached :documents
  has_rich_text     :body  # Action Text

  # ── Enums ───────────────────────────────────────────────────────────────────
  enum :status, { draft: 0, published: 1, archived: 2 }, default: :draft, validate: true

  # ── Validations ─────────────────────────────────────────────────────────────
  validates :title,  presence: true, length: { maximum: 255 }
  validates :slug,   presence: true, uniqueness: true, format: { with: /\A[a-z0-9-]+\z/ }
  validates :status, presence: true

  validates :cover_image,
            content_type: %w[image/png image/jpeg image/webp],
            size: { less_than: 5.megabytes },
            if: :cover_image_attached?

  validate :publish_date_cannot_be_in_past, if: :published?

  # ── Scopes ──────────────────────────────────────────────────────────────────
  scope :published,     -> { where(status: :published) }
  scope :drafts,        -> { where(status: :draft) }
  scope :recent,        -> { order(published_at: :desc) }
  scope :featured,      -> { where(featured: true) }
  scope :by_author,     ->(author_id) { where(author_id: author_id) }
  scope :created_after, ->(date) { where("created_at >= ?", date) }
  scope :search,        ->(query) { where("title ILIKE ? OR excerpt ILIKE ?", "%#{query}%", "%#{query}%") }

  # Eager loading scopes (prevent N+1)
  scope :with_associations, -> { includes(:author, :category, :tags) }
  scope :feed, -> { published.recent.with_associations.limit(20) }

  # ── Callbacks ───────────────────────────────────────────────────────────────
  before_validation :generate_slug, on: :create
  before_save       :set_published_at, if: :publishing?
  after_create_commit  :notify_subscribers
  after_update_commit  :broadcast_update
  after_destroy_commit :cleanup_assets

  # ── Encryption (Rails 7+) ──────────────────────────────────────────────────
  # encrypts :internal_notes

  # ── Class methods ───────────────────────────────────────────────────────────
  def self.trending(limit: 10)
    published
      .where("published_at > ?", 7.days.ago)
      .order(views_count: :desc)
      .limit(limit)
  end

  # ── Instance methods ────────────────────────────────────────────────────────
  def publish!
    update!(status: :published, published_at: Time.current)
  end

  def archive!
    update!(status: :archived)
  end

  def reading_time
    words_per_minute = 200
    word_count = body&.to_plain_text&.split&.size || 0
    (word_count / words_per_minute.to_f).ceil
  end

  def to_param
    slug
  end

  private

  # ── Private methods ─────────────────────────────────────────────────────────
  def generate_slug
    self.slug = title&.parameterize if slug.blank?
  end

  def set_published_at
    self.published_at ||= Time.current
  end

  def publishing?
    status_changed? && published?
  end

  def publish_date_cannot_be_in_past
    if published_at.present? && published_at < Time.current - 1.minute
      errors.add(:published_at, "can't be in the past")
    end
  end

  def cover_image_attached?
    cover_image.attached?
  end

  def notify_subscribers
    ArticleNotificationJob.perform_later(id)
  end

  def broadcast_update
    broadcast_replace_to "articles", partial: "articles/article", locals: { article: self }
  end

  def cleanup_assets
    cover_image.purge_later if cover_image.attached?
  end
end
