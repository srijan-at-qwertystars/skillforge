# Rails API Reference

> Complete cheat sheet for Active Record queries, migrations, routing, controllers, testing, and CLI.

## Table of Contents

- [Active Record Query Interface](#active-record-query-interface)
- [Migration Methods](#migration-methods)
- [Routing DSL](#routing-dsl)
- [Controller Callbacks](#controller-callbacks)
- [Testing — Minitest](#testing--minitest)
- [Testing — RSpec](#testing--rspec)
- [Rails CLI Commands](#rails-cli-commands)

---

## Active Record Query Interface

### Finders

```ruby
User.find(1)                          # raises RecordNotFound
User.find([1, 2, 3])                  # returns array
User.find_by(email: "a@b.com")       # returns nil if missing
User.find_by!(email: "a@b.com")      # raises RecordNotFound
User.find_sole_by(email: "a@b.com")  # raises if 0 or >1 results
User.first                            # ORDER BY id ASC LIMIT 1
User.last                             # ORDER BY id DESC LIMIT 1
User.take                             # no ordering, LIMIT 1
User.first!                           # raises if none
User.find_or_create_by(email: "a@b.com") { |u| u.name = "New" }
User.find_or_initialize_by(email: "a@b.com")
User.sole                             # exactly one record or raise
```

### Conditions

```ruby
User.where(active: true)
User.where("age > ?", 18)
User.where("name LIKE ?", "%john%")
User.where(age: 18..35)               # BETWEEN
User.where(role: [:admin, :mod])       # IN
User.where.not(role: :banned)
User.where(active: true).or(User.where(admin: true))
User.where.missing(:profile)          # LEFT JOIN WHERE NULL (Rails 7+)
User.where.associated(:profile)       # INNER JOIN EXISTS (Rails 7+)
User.invert_where                     # negate previous where
```

### Ordering and limiting

```ruby
User.order(:name)
User.order(name: :asc, created_at: :desc)
User.reorder(:email)                  # replaces existing order
User.reverse_order
User.limit(10).offset(20)
User.distinct
```

### Selecting and plucking

```ruby
User.select(:id, :name)
User.select("COUNT(*) AS count, role").group(:role)
User.pluck(:email)                    # => ["a@b.com", ...]
User.pick(:email)                     # => "a@b.com" (first only)
User.ids                              # pluck(:id)
User.count
User.sum(:balance)
User.average(:age)
User.minimum(:created_at)
User.maximum(:updated_at)
```

### Joins

```ruby
User.joins(:articles)                 # INNER JOIN
User.left_joins(:profile)             # LEFT OUTER JOIN
User.joins(:articles).where(articles: { published: true })
User.joins("JOIN articles ON articles.user_id = users.id")

# Eager loading (N+1 prevention)
User.includes(:articles)              # preload or eager_load
User.preload(:articles)               # separate queries
User.eager_load(:articles)            # LEFT OUTER JOIN
User.includes(:articles).references(:articles)  # force JOIN for where
```

### Scopes and chaining

```ruby
class User < ApplicationRecord
  scope :active, -> { where(active: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :admins, -> { where(role: :admin) }
  scope :created_after, ->(date) { where("created_at > ?", date) }
end

User.active.admins.recent.limit(5)
User.active.or(User.admins)
User.none                             # empty relation (chainable)
User.all                              # all records (chainable)
```

### Batch processing

```ruby
User.find_each(batch_size: 500) { |user| process(user) }
User.find_in_batches(batch_size: 500) { |batch| batch.each { ... } }
User.in_batches(of: 500) { |relation| relation.update_all(active: false) }
```

### Locking

```ruby
User.lock.find(1)                     # SELECT ... FOR UPDATE
User.lock("FOR UPDATE NOWAIT").find(1)

# Optimistic locking — add lock_version:integer column
user = User.find(1)
user.update!(name: "New")  # raises StaleObjectError if version mismatch
```

### Mutations

```ruby
User.create!(name: "Jo", email: "j@b.com")
user.update!(name: "New")
user.update_attribute(:name, "New")    # skips validations
User.update_all(active: false)         # bulk, no callbacks
user.destroy                           # runs callbacks
user.delete                            # skips callbacks
User.delete_all                        # bulk, no callbacks
User.destroy_all                       # iterates + callbacks
user.toggle(:admin).save!
user.increment!(:login_count)
User.upsert_all(records, unique_by: :email)  # bulk upsert
User.insert_all(records)              # bulk insert, skip duplicates
```

### Async queries

```ruby
users  = User.active.load_async       # fires query in background
count  = User.active.count_async       # => Promise
total  = User.sum_async(:balance)
# Calling .value or iterating blocks until complete
```

---

## Migration Methods

### Table operations

```ruby
create_table :users do |t|
  t.string   :name, null: false
  t.string   :email, null: false, index: { unique: true }
  t.integer  :age
  t.decimal  :balance, precision: 10, scale: 2, default: 0
  t.boolean  :active, default: true, null: false
  t.text     :bio
  t.date     :birthday
  t.datetime :last_login
  t.json     :metadata, default: {}
  t.binary   :avatar
  t.references :team, foreign_key: true, null: false  # team_id + index + FK
  t.timestamps                          # created_at, updated_at
end

create_table :routes, primary_key: [:origin, :dest] do |t| ... end  # composite PK
create_table :items, id: :uuid do |t| ... end                       # UUID PK

drop_table :users
rename_table :users, :accounts
change_table :users do |t|
  t.remove :age
  t.string :phone
end
```

### Column operations

```ruby
add_column    :users, :phone, :string
remove_column :users, :phone, :string   # specify type for reversibility
change_column :users, :name, :text
rename_column :users, :name, :full_name
change_column_default :users, :active, from: nil, to: true
change_column_null    :users, :name, false  # NOT NULL
```

### Index operations

```ruby
add_index    :users, :email, unique: true
add_index    :users, [:last_name, :first_name]
add_index    :users, :email, algorithm: :concurrently  # PG non-blocking
remove_index :users, :email
```

### Reference / foreign key operations

```ruby
add_reference    :articles, :author, foreign_key: { to_table: :users }
remove_reference :articles, :author
add_foreign_key  :articles, :users, column: :author_id
remove_foreign_key :articles, :users
```

### Data operations in migrations

```ruby
reversible do |dir|
  dir.up   { User.update_all(active: true) }
  dir.down { User.update_all(active: nil) }
end

# Execute raw SQL
execute "UPDATE users SET role = 'member' WHERE role IS NULL"
```

### Column types reference

| Type | Ruby | PostgreSQL | MySQL |
|------|------|-----------|-------|
| `:string` | String | varchar(255) | varchar(255) |
| `:text` | String | text | text |
| `:integer` | Integer | integer | int(11) |
| `:bigint` | Integer | bigint | bigint |
| `:float` | Float | float8 | float |
| `:decimal` | BigDecimal | decimal | decimal |
| `:boolean` | TrueClass | boolean | tinyint(1) |
| `:date` | Date | date | date |
| `:datetime` | DateTime | timestamp | datetime |
| `:time` | Time | time | time |
| `:json` | Hash/Array | json | json |
| `:jsonb` | Hash/Array | jsonb | — |
| `:uuid` | String | uuid | char(36) |
| `:binary` | String | bytea | blob |

---

## Routing DSL

### Resource routing

```ruby
Rails.application.routes.draw do
  root "pages#home"

  # Full CRUD: index, show, new, create, edit, update, destroy
  resources :articles

  # Subset of actions
  resources :articles, only: %i[index show]
  resources :articles, except: %i[destroy]

  # Singular resource (no index, no :id in URL)
  resource :profile, only: %i[show edit update]

  # Nested (max 1 level deep)
  resources :articles do
    resources :comments, only: %i[create destroy], shallow: true
  end

  # Member and collection routes
  resources :articles do
    member do
      post :publish          # /articles/:id/publish
      patch :archive
    end
    collection do
      get :search            # /articles/search
      get :drafts
    end
  end
end
```

### Namespace, scope, and module

```ruby
# Namespace: URL prefix + module + path prefix
namespace :admin do
  resources :articles        # Admin::ArticlesController, /admin/articles
end

# Scope: URL prefix only
scope "/api/v1" do
  resources :articles        # ArticlesController, /api/v1/articles
end

# Module: controller module only
scope module: :api do
  resources :articles        # Api::ArticlesController, /articles
end

# Combined
namespace :api do
  namespace :v1 do
    resources :articles      # Api::V1::ArticlesController, /api/v1/articles
  end
end
```

### Constraints and advanced

```ruby
# Subdomain constraint
constraints subdomain: "api" do
  resources :articles
end

# Format constraint
resources :articles, defaults: { format: :json }

# Custom constraint class
class AdminConstraint
  def matches?(request)
    request.session[:admin] == true
  end
end
constraints AdminConstraint.new do
  mount Sidekiq::Web => "/sidekiq"
end

# Direct and resolve
direct(:homepage) { "https://example.com" }
resolve("Article") { |article| [:blog, article] }  # polymorphic URL

# Concerns (reusable route blocks)
concern :commentable do
  resources :comments, only: %i[create destroy]
end
resources :articles, concerns: :commentable
resources :photos, concerns: :commentable
```

### Route helpers

```ruby
articles_path         # /articles
article_path(@a)      # /articles/1
new_article_path      # /articles/new
edit_article_path(@a) # /articles/1/edit
article_url(@a)       # https://example.com/articles/1
```

---

## Controller Callbacks

### Available callbacks

```ruby
class ApplicationController < ActionController::Base
  before_action   :authenticate_user!
  after_action    :log_activity
  around_action   :wrap_in_transaction
  skip_before_action :authenticate_user!, only: %i[index show]
end
```

### Callback options

```ruby
before_action :set_article, only: %i[show edit update destroy]
before_action :require_admin, except: %i[index show]
before_action :check_feature_flag, if: :logged_in?
before_action :rate_limit, unless: -> { current_user&.admin? }
prepend_before_action :set_locale  # runs first
```

### Common patterns

```ruby
class ApplicationController < ActionController::Base
  # Locale
  around_action :switch_locale
  def switch_locale(&action)
    locale = params[:locale] || I18n.default_locale
    I18n.with_locale(locale, &action)
  end

  # Error handling
  rescue_from ActiveRecord::RecordNotFound, with: :not_found
  rescue_from Pundit::NotAuthorizedError, with: :forbidden

  private
  def not_found
    render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
  end

  def forbidden
    redirect_to root_path, alert: "Not authorized."
  end
end
```

### Action-level rendering

```ruby
class ArticlesController < ApplicationController
  def create
    @article = current_user.articles.build(article_params)
    if @article.save
      respond_to do |format|
        format.html { redirect_to @article, notice: "Created." }
        format.turbo_stream
        format.json { render json: @article, status: :created }
      end
    else
      render :new, status: :unprocessable_entity
    end
  end
end
```

---

## Testing — Minitest

### Assertions reference

```ruby
# Basic
assert              expression               # truthy
assert_not          expression               # falsy (alias: refute)
assert_equal        expected, actual
assert_not_equal    expected, actual
assert_nil          object
assert_not_nil      object
assert_empty        collection
assert_includes     collection, item
assert_match        /regex/, string
assert_instance_of  String, object
assert_kind_of      Numeric, object
assert_respond_to   object, :method_name
assert_raises(ActiveRecord::RecordInvalid) { code }
assert_nothing_raised { code }
assert_in_delta     expected, actual, delta

# Rails-specific
assert_difference    "User.count", 1 do ... end
assert_no_difference "User.count" do ... end
assert_changes       -> { user.name }, from: "Old", to: "New" do ... end
assert_no_changes    -> { user.email } do ... end

# Controller/integration
assert_response      :success          # 200
assert_response      :redirect         # 3xx
assert_response      :not_found        # 404
assert_response      :unprocessable_entity  # 422
assert_redirected_to article_path(@article)
assert_template      "articles/show"   # deprecated in Rails 7+

# DOM assertions (system tests)
assert_selector      "h1", text: "Title"
assert_no_selector   ".error"
assert_text          "Welcome"
assert_no_text       "Error"
```

### Test structure

```ruby
class ArticleTest < ActiveSupport::TestCase
  setup do
    @article = articles(:published)
  end

  test "should be valid with title" do
    assert @article.valid?
  end

  test "should require title" do
    @article.title = nil
    assert_not @article.valid?
    assert_includes @article.errors[:title], "can't be blank"
  end
end

class ArticlesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:admin)
    sign_in @user  # if using Devise
  end

  test "should create article" do
    assert_difference("Article.count") do
      post articles_url, params: { article: { title: "New", body: "Content" } }
    end
    assert_redirected_to article_url(Article.last)
  end
end
```

---

## Testing — RSpec

### Matchers reference

```ruby
# Equality
expect(x).to eq(y)                    # ==
expect(x).to eql(y)                   # .eql?
expect(x).to equal(y)                 # .equal? (identity)
expect(x).to be(y)                    # same as equal

# Truthiness
expect(x).to be_truthy
expect(x).to be_falsey
expect(x).to be_nil
expect(x).to be true                  # exact true

# Comparisons
expect(x).to be > 5
expect(x).to be_between(1, 10).inclusive
expect(x).to be_within(0.1).of(3.14)

# Types
expect(x).to be_a(String)
expect(x).to be_an(Integer)
expect(x).to respond_to(:name)
expect(x).to have_attributes(name: "Jo", age: 25)

# Collections
expect(arr).to include(1, 2)
expect(arr).to contain_exactly(3, 1, 2)  # order-independent
expect(arr).to match_array([3, 1, 2])
expect(arr).to start_with(1)
expect(arr).to all(be > 0)
expect(hash).to include(key: "value")
expect(arr).to be_empty
expect(arr).to have_exactly(3).items     # needs rspec-collection_matchers

# Strings
expect(str).to match(/regex/)
expect(str).to start_with("Hello")
expect(str).to end_with("world")
expect(str).to include("substr")

# Errors
expect { code }.to raise_error(RuntimeError)
expect { code }.to raise_error(RuntimeError, "message")
expect { code }.not_to raise_error

# Changes
expect { code }.to change(User, :count).by(1)
expect { code }.to change { user.reload.name }.from("Old").to("New")
expect { code }.not_to change(User, :count)

# Shoulda matchers (shoulda-matchers gem)
expect(user).to validate_presence_of(:name)
expect(user).to validate_uniqueness_of(:email).case_insensitive
expect(user).to validate_length_of(:name).is_at_most(100)
expect(user).to validate_numericality_of(:age).is_greater_than(0)
expect(user).to belong_to(:team)
expect(user).to have_many(:articles).dependent(:destroy)
expect(user).to have_one(:profile)
expect(user).to have_many(:tags).through(:taggings)
expect(user).to accept_nested_attributes_for(:profile)
expect(user).to have_secure_password
expect(user).to define_enum_for(:role).with_values(admin: 0, member: 1)
```

### RSpec structure

```ruby
RSpec.describe Article, type: :model do
  subject { build(:article) }

  describe "validations" do
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to belong_to(:author) }
  end

  describe "#publish!" do
    let(:article) { create(:article, published: false) }

    it "marks article as published" do
      expect { article.publish! }.to change { article.published }.from(false).to(true)
    end

    context "when already published" do
      let(:article) { create(:article, :published) }
      it "raises error" do
        expect { article.publish! }.to raise_error(Article::AlreadyPublishedError)
      end
    end
  end
end

RSpec.describe "Articles", type: :request do
  let(:user) { create(:user) }
  before { sign_in user }

  describe "POST /articles" do
    let(:valid_params) { { article: attributes_for(:article) } }

    it "creates an article" do
      expect { post articles_path, params: valid_params }
        .to change(Article, :count).by(1)
      expect(response).to redirect_to(article_path(Article.last))
    end
  end
end
```

---

## Rails CLI Commands

### App generation

```bash
rails new myapp                        # full app
rails new myapp --api                  # API-only
rails new myapp --database=postgresql  # specify DB
rails new myapp --css=tailwind         # CSS framework
rails new myapp --skip-test            # skip Minitest (use with RSpec)
rails new myapp --skip-jbuilder        # skip JSON builder
rails new myapp --skip-action-mailer   # skip mailer
```

### Generators

```bash
rails g model User name:string email:string:uniq admin:boolean
rails g model Article title:string body:text user:references
rails g controller Articles index show new create edit update destroy
rails g scaffold Post title:string body:text published:boolean
rails g migration AddPhoneToUsers phone:string
rails g migration CreateJoinTableUsersRoles users roles
rails g mailer UserMailer welcome reset_password
rails g job ProcessPayment
rails g channel Chat speak
rails g authentication                 # Rails 8 auth scaffold
rails g stimulus search                # Stimulus controller
rails destroy model User               # undo generator
```

### Database

```bash
rails db:create                        # create databases
rails db:drop                          # drop databases
rails db:migrate                       # run pending migrations
rails db:migrate:status                # show migration status
rails db:rollback                      # undo last migration
rails db:rollback STEP=3               # undo last 3
rails db:migrate VERSION=20240101      # migrate to specific version
rails db:seed                          # run db/seeds.rb
rails db:reset                         # drop + create + migrate + seed
rails db:setup                         # create + migrate + seed
rails db:schema:load                   # load schema.rb (faster than migrate)
rails db:schema:dump                   # generate schema.rb from DB
rails db:prepare                       # create if needed + migrate (deploy-safe)
rails db:encryption:init               # generate encryption keys
```

### Console and server

```bash
rails console                          # IRB with app loaded
rails console --sandbox                # auto-rollback on exit
rails server                           # start Puma (default port 3000)
rails server -p 4000 -b 0.0.0.0       # custom port and binding
rails runner "User.count"              # run one-liner
rails runner scripts/backfill.rb       # run script file
```

### Routes and tasks

```bash
rails routes                           # all routes
rails routes -g articles               # grep routes
rails routes -c ArticlesController     # controller-specific
rails stats                            # code statistics
rails notes                            # show TODO/FIXME/OPTIMIZE
rails zeitwerk:check                   # validate autoloading
rails tmp:clear                        # clear tmp/
rails log:clear                        # clear logs
rails secret                           # generate secret key
rails credentials:edit                 # edit encrypted credentials
rails credentials:edit --environment production
```

### Testing

```bash
rails test                             # all tests
rails test test/models                 # directory
rails test test/models/user_test.rb    # specific file
rails test test/models/user_test.rb:42 # specific line
rails test:system                      # system tests
RAILS_ENV=test rails db:prepare        # prepare test DB
```

### Asset pipeline

```bash
rails assets:precompile               # compile for production
rails assets:clean                     # remove old compiled assets
rails assets:clobber                   # remove all compiled assets
```

### Rake tasks (also available as `rails` commands)

```bash
rails middleware                       # list middleware stack
rails initializers                     # list initializers with order
rails about                            # Ruby, Rails, DB versions
```
