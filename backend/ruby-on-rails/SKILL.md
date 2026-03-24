---
name: ruby-on-rails
description: >
  Expert Ruby on Rails 7.x/8.x development guidance. Covers MVC, Active Record (migrations,
  associations, validations, scopes, N+1 prevention), Action Controller (strong params, filters,
  routing), Action View (Turbo/Stimulus/Hotwire), Active Job + Solid Queue, Action Cable,
  Action Mailer, Active Storage, API mode, Rails 8 (Solid Cache/Cable, Kamal, Propshaft,
  auth generator), testing (RSpec, Minitest, FactoryBot), Devise, Pundit, service objects, caching.
  Triggers: "Rails", "Ruby on Rails", "Active Record", "Rails API", "Rails migration",
  "Turbo", "Hotwire", "Stimulus", "Action Cable", "Solid Queue", "Rails controller".
  NOT for plain Ruby without Rails, NOT for Sinatra/Hanami/Roda, NOT for Django/Laravel/Express.
---

# Ruby on Rails Skill

## Core Principles

Follow Convention over Configuration and DRY. Prefer Rails defaults before gems.
Keep controllers thin, models focused on persistence, complex logic in service objects.
Use generators for boilerplate. Never edit `schema.rb` manually.

## Active Record

### Migrations

```ruby
# Input: rails generate migration CreateArticles title:string body:text published:boolean
# Output:
class CreateArticles < ActiveRecord::Migration[8.0]
  def change
    create_table :articles do |t|
      t.string :title, null: false
      t.text :body
      t.boolean :published, default: false
      t.timestamps
    end
    add_index :articles, :title
  end
end
```

Use `change` for reversible migrations, `up`/`down` for irreversible.
Always add `null: false`, database defaults, and indexes on foreign keys and queried columns.

### Associations

```ruby
class Author < ApplicationRecord
  has_many :articles, dependent: :destroy
  has_many :comments, through: :articles
  has_one :profile, dependent: :destroy
end

class Article < ApplicationRecord
  belongs_to :author
  has_many :comments, dependent: :destroy
  has_many :tags, through: :taggings
  has_one_attached :cover_image  # Active Storage
end
```

Prefer `has_many :through` over HABTM. Always set `dependent:`. Use `inverse_of:` when Rails cannot infer.

### Validations

```ruby
class Article < ApplicationRecord
  validates :title, presence: true, length: { maximum: 255 }
  validates :slug, presence: true, uniqueness: true
  validates :status, inclusion: { in: %w[draft published archived] }
  validate :publish_date_cannot_be_in_past
end
```

Always pair uniqueness validations with a database unique index.

### Scopes and Queries

```ruby
class Article < ApplicationRecord
  scope :published, -> { where(published: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_author, ->(author_id) { where(author_id: author_id) }
end
# Compose: Article.published.recent.by_author(user.id).limit(10)
```

### N+1 Prevention

```ruby
# BAD: Article.all.each { |a| a.author.name }
# GOOD:
Article.includes(:author).each { |a| a.author.name }

# includes: preloads or joins as needed
# eager_load: forces LEFT OUTER JOIN
# preload: forces separate queries
# Nested: Article.includes(author: :profile, comments: :user)

# Enforce at runtime:
Article.strict_loading.find(params[:id])
# Use bullet gem in development to detect N+1 automatically.
```

### Callbacks

Use sparingly. Prefer service objects for side effects.

```ruby
before_validation :generate_slug, on: :create
after_create_commit :notify_subscribers  # after_commit, not after_save
```

## Action Controller

### Strong Parameters

```ruby
class ArticlesController < ApplicationController
  def create
    @article = current_user.articles.build(article_params)
    if @article.save
      redirect_to @article, notice: "Article created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  # Rails 8: params.expect instead of params.require.permit
  def article_params
    params.expect(article: [:title, :body, :published, :category_id, tags: []])
  end
end
```

### Filters

```ruby
class ApplicationController < ActionController::Base
  before_action :authenticate_user!
end

class ArticlesController < ApplicationController
  before_action :set_article, only: %i[show edit update destroy]
  skip_before_action :authenticate_user!, only: %i[index show]
end
```

### Routing

```ruby
Rails.application.routes.draw do
  root "pages#home"
  resources :articles do
    resources :comments, only: %i[create destroy]
    member { post :publish }
    collection { get :search }
  end
  namespace :api do
    namespace :v1 do
      resources :articles, only: %i[index show create update]
    end
  end
  resource :profile, only: %i[show edit update]
end
```

Use `resources` for REST. Namespace API versions. Max 1 level of nesting.

## Action View — Hotwire

### Turbo Frames

```erb
<%= turbo_frame_tag "articles" do %>
  <%= render partial: "article", collection: @articles %>
<% end %>

<%= turbo_frame_tag "trending", src: trending_articles_path, loading: :lazy do %>
  <p>Loading...</p>
<% end %>
```

### Turbo Streams

```ruby
# Model broadcasting (Rails 8):
class Comment < ApplicationRecord
  broadcasts_refreshes_to :article
end
```

```erb
<%# app/views/comments/create.turbo_stream.erb %>
<%= turbo_stream.append "comments", @comment %>
```

### Stimulus

```javascript
// app/javascript/controllers/toggle_controller.js
import { Controller } from "@hotwired/stimulus"
export default class extends Controller {
  static targets = ["content"]
  toggle() { this.contentTarget.classList.toggle("hidden") }
}
```

```erb
<div data-controller="toggle">
  <button data-action="click->toggle#toggle">Toggle</button>
  <div data-toggle-target="content">Content here</div>
</div>
```

### Partials

```erb
<%= render partial: "article", collection: @articles, cached: true %>
```

Use `collection:` rendering over loops — Rails batches cache reads automatically.

## Active Job + Solid Queue

```ruby
class ArticlePublishJob < ApplicationJob
  queue_as :default
  retry_on ActiveRecord::Deadlocked, wait: 5.seconds, attempts: 3
  discard_on ActiveJob::DeserializationError

  def perform(article)
    article.update!(published: true, published_at: Time.current)
    ArticleMailer.published_notification(article).deliver_later
  end
end
# Enqueue: ArticlePublishJob.perform_later(article)
```

Solid Queue uses your database — no Redis required. Configure recurring jobs in `config/recurring.yml`.

## Action Cable

```ruby
class ChatChannel < ApplicationCable::Channel
  def subscribed
    stream_from "chat_#{params[:room_id]}"
  end
  def speak(data)
    Message.create!(body: data["body"], user: current_user, room_id: params[:room_id])
  end
end
# Broadcast: ActionCable.server.broadcast("chat_#{room.id}", { body: msg.body })
```

Rails 8 Solid Cable: database-backed adapter, no Redis needed.

## Action Mailer

```ruby
class ArticleMailer < ApplicationMailer
  def published_notification(article)
    @article = article
    mail(to: article.author.email, subject: "Your article is live!")
  end
end
# Always: deliver_later (via Active Job), not deliver_now
```

## API Mode

```ruby
# rails new myapi --api
class Api::V1::ArticlesController < ActionController::API
  def index
    articles = Article.includes(:author).published.page(params[:page])
    render json: articles, each_serializer: ArticleSerializer, status: :ok
  end
  def create
    article = current_user.articles.build(article_params)
    if article.save
      render json: article, status: :created
    else
      render json: { errors: article.errors.full_messages }, status: :unprocessable_entity
    end
  end
end
```

Use `ActionController::API` for API-only. Prefer `jbuilder` or `jsonapi-serializer`.

## Authentication

### Rails 8 Generator

```bash
# Input: rails generate authentication
# Output: User model with has_secure_password, Session model/controller, views, migrations
```

### Devise (complex auth needs)

```ruby
class User < ApplicationRecord
  devise :database_authenticatable, :registerable, :recoverable,
         :rememberable, :validatable, :confirmable, :lockable
end
```

## Authorization — Pundit

```ruby
class ArticlePolicy < ApplicationPolicy
  def update? = user.admin? || record.author == user
  def destroy? = user.admin?

  class Scope < ApplicationPolicy::Scope
    def resolve
      user.admin? ? scope.all : scope.where(author: user).or(scope.where(published: true))
    end
  end
end
# Controller: authorize @article
# Index: policy_scope(Article)
# Add after_action :verify_authorized to catch missing auth checks.
```

## Service Objects

```ruby
# app/services/articles/publish_service.rb
module Articles
  class PublishService
    def initialize(article, user:)
      @article = article
      @user = user
    end

    def call
      return failure("Not authorized") unless ArticlePolicy.new(@user, @article).publish?
      ActiveRecord::Base.transaction do
        @article.update!(published: true, published_at: Time.current)
      end
      ArticlePublishJob.perform_later(@article)
      success(@article)
    rescue ActiveRecord::RecordInvalid => e
      failure(e.message)
    end

    private
    def success(data) = OpenStruct.new(success?: true, data: data)
    def failure(error) = OpenStruct.new(success?: false, error: error)
  end
end
# Usage: result = Articles::PublishService.new(article, user: current_user).call
```

Place in `app/services/`. Single public `call` method. Return result objects.

## Concerns

```ruby
# app/models/concerns/sluggable.rb
module Sluggable
  extend ActiveSupport::Concern
  included do
    before_validation :generate_slug, on: :create
    validates :slug, presence: true, uniqueness: true
  end
  private
  def generate_slug
    self.slug = title&.parameterize if slug.blank?
  end
end
# Usage: include Sluggable
```

Keep concerns small — one behavior per concern.

## Caching

```ruby
# Fragment caching:
<% cache @article do %>
  <%= render @article %>
<% end %>

# Low-level:
Rails.cache.fetch("trending", expires_in: 1.hour) do
  Article.published.order(views_count: :desc).limit(10).to_a
end

# HTTP caching:
def show
  @article = Article.find(params[:id])
  fresh_when(@article)
end

# Counter cache to avoid COUNT queries:
belongs_to :article, counter_cache: true
```

Rails 8 Solid Cache: database-backed, no Redis/Memcached needed.

## Testing

### RSpec

```ruby
RSpec.describe Article, type: :model do
  it { is_expected.to validate_presence_of(:title) }
  it { is_expected.to belong_to(:author) }
  it { is_expected.to have_many(:comments).dependent(:destroy) }

  describe ".published" do
    it "returns only published articles" do
      published = create(:article, published: true)
      create(:article, published: false)
      expect(Article.published).to eq([published])
    end
  end
end

RSpec.describe "Articles", type: :request do
  let(:user) { create(:user) }
  before { sign_in user }
  it "creates an article" do
    expect { post articles_path, params: { article: attributes_for(:article) } }
      .to change(Article, :count).by(1)
  end
end
```

### FactoryBot

```ruby
FactoryBot.define do
  factory :article do
    title { Faker::Lorem.sentence }
    body { Faker::Lorem.paragraphs(number: 3).join("\n\n") }
    published { false }
    association :author, factory: :user
    trait(:published) { published { true }; published_at { Time.current } }
  end
end
```

## Rails 8 Features

| Feature | Replaces | Benefit |
|---|---|---|
| Solid Cache | Redis/Memcached | DB-backed persistent cache |
| Solid Queue | Sidekiq/Redis | DB-backed job queue with recurring jobs |
| Solid Cable | Redis adapter | DB-backed Action Cable |
| Propshaft | Sprockets | Simpler asset pipeline, HTTP/2 |
| Kamal 2 + Thruster | Capistrano/Heroku | Docker zero-downtime deploy, built-in proxy |
| `rails g authentication` | Devise (basic) | Built-in session auth scaffold |
| `params.expect` | `require.permit` | Safer strong params |

## Anti-Patterns to Avoid

- Fat controllers — extract to service objects
- Missing database indexes on foreign keys / queried columns
- `after_save` for external side effects — use `after_commit`
- N+1 queries — use `includes`/`preload`/`eager_load`
- Deeply nested routes beyond one level
- Complex callbacks — use service objects instead
- Missing `dependent:` on `has_many`/`has_one`
- Skipping `null: false` and unique indexes at database level
- Not running `bundle audit` for security vulnerabilities

## References

| File | Description |
|------|-------------|
| `references/advanced-patterns.md` | Custom generators, Rails engines, multi-database, encryption, Action Text/Mailbox, composite PKs, async queries, strict loading, query logs, horizontal sharding, Turbo Streams advanced, Stimulus composition |
| `references/troubleshooting.md` | N+1 (Bullet gem), slow migrations, memory bloat, Sprockets→Propshaft migration, Zeitwerk errors, connection pool exhaustion, CSRF in API mode, Turbo debugging, Rails 7→8 upgrade guide |
| `references/api-reference.md` | Active Record query interface, migration methods, routing DSL, controller callbacks, Minitest assertions, RSpec matchers, Rails CLI commands |

## Scripts

| File | Description |
|------|-------------|
| `scripts/setup-rails.sh` | Generate new Rails app with recommended gems, RSpec, Bullet, Pundit, and production config |
| `scripts/audit-queries.sh` | Find N+1 queries, missing indexes, associations without `dependent:`, and missing strict_loading |
| `scripts/upgrade-rails.sh` | Automated Rails upgrade checklist: version checks, deprecation scan, Zeitwerk validation, test run, and report |

## Assets (Templates)

| File | Description |
|------|-------------|
| `assets/service-object.rb` | Service object pattern with Result struct, validation, transactions, dependency injection |
| `assets/model-template.rb` | Active Record model with associations, validations, scopes, callbacks, enums, encryption |
| `assets/controller-template.rb` | RESTful controller with strong params, Pundit auth, Turbo Stream responses, pagination |
| `assets/stimulus-controller.js` | Stimulus controller with targets, values (reactive), actions, outlets, CSS classes, fetch |
| `assets/Gemfile` | Production-ready Gemfile: Rails 8 + Solid Queue/Cache/Cable, Pundit, Pagy, RSpec, monitoring |

<!-- tested: pass -->
