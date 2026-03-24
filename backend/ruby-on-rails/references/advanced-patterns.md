# Advanced Rails Patterns

> Dense reference for Rails 7.x/8.x advanced features. Each section is self-contained with production-ready code.

## Table of Contents

- [Custom Generators](#custom-generators)
- [Rails Engines](#rails-engines)
- [Multi-Database Setup](#multi-database-setup)
- [Active Record Encryption](#active-record-encryption)
- [Action Text](#action-text)
- [Action Mailbox](#action-mailbox)
- [Composite Primary Keys](#composite-primary-keys)
- [Async Queries](#async-queries)
- [Strict Loading](#strict-loading)
- [Query Logs](#query-logs)
- [Horizontal Sharding](#horizontal-sharding)
- [Turbo Streams Advanced](#turbo-streams-advanced)
- [Stimulus Controller Composition](#stimulus-controller-composition)

---

## Custom Generators

Create domain-specific generators in `lib/generators/`:

```ruby
# lib/generators/service/service_generator.rb
class ServiceGenerator < Rails::Generators::NamedBase
  source_root File.expand_path("templates", __dir__)
  argument :actions, type: :array, default: [], banner: "action action"

  def create_service_file
    template "service.rb.tt", File.join("app/services", class_path, "#{file_name}_service.rb")
  end

  def create_test_file
    template "service_test.rb.tt", File.join("test/services", class_path, "#{file_name}_service_test.rb")
  end
end
```

```ruby
# lib/generators/service/templates/service.rb.tt
<% module_namespacing do -%>
class <%= class_name %>Service
  def initialize(<%= actions.map { |a| "#{a}:" }.join(", ") %>)
<% actions.each do |action| -%>
    @<%= action %> = <%= action %>
<% end -%>
  end

  def call
    # TODO: implement
  end
end
<% end -%>
```

Run: `rails generate service Users::Registration email password`

### Generator hooks

```ruby
# config/application.rb
config.generators do |g|
  g.orm             :active_record, primary_key_type: :uuid
  g.test_framework  :rspec, fixture: false
  g.helper          false
  g.assets          false
  g.view_specs      false
  g.routing_specs   false
  g.stylesheets     false
end
```

---

## Rails Engines

### Creating a mountable engine

```bash
rails plugin new my_engine --mountable --database=postgresql
```

### Engine structure

```ruby
# my_engine/lib/my_engine/engine.rb
module MyEngine
  class Engine < ::Rails::Engine
    isolate_namespace MyEngine

    initializer "my_engine.assets" do |app|
      app.config.assets.paths << root.join("app/assets")
    end

    config.generators do |g|
      g.test_framework :rspec
      g.fixture_replacement :factory_bot, dir: "spec/factories"
    end
  end
end
```

### Mounting in host app

```ruby
# Host config/routes.rb
Rails.application.routes.draw do
  mount MyEngine::Engine, at: "/engine"
end
```

### Sharing models via concerns

```ruby
# Engine: app/models/concerns/my_engine/taggable.rb
module MyEngine::Taggable
  extend ActiveSupport::Concern
  included do
    has_many :taggings, as: :taggable, class_name: "MyEngine::Tagging"
    has_many :tags, through: :taggings, class_name: "MyEngine::Tag"
  end
end

# Host app model:
class Article < ApplicationRecord
  include MyEngine::Taggable
end
```

---

## Multi-Database Setup

### Configuration

```yaml
# config/database.yml
production:
  primary:
    <<: *default
    database: myapp_primary
  primary_replica:
    <<: *default
    database: myapp_primary
    replica: true
  analytics:
    <<: *default
    database: myapp_analytics
    migrations_paths: db/analytics_migrate
  queue:
    <<: *default
    database: myapp_queue
    migrations_paths: db/queue_migrate
```

### Model connection

```ruby
class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :primary, reading: :primary_replica }
end

class AnalyticsRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :analytics, reading: :analytics }
end

class PageView < AnalyticsRecord
  # queries go to analytics DB
end
```

### Automatic role switching

```ruby
# config/application.rb
config.active_record.database_selector = { delay: 2.seconds }
config.active_record.database_resolver = ActiveRecord::Middleware::DatabaseSelector::Resolver
config.active_record.database_resolver_context =
  ActiveRecord::Middleware::DatabaseSelector::Resolver::Session
```

### Manual switching

```ruby
ActiveRecord::Base.connected_to(role: :reading) do
  # all queries in this block go to replica
  Article.published.recent
end

ActiveRecord::Base.connected_to(database: :analytics) do
  PageView.where(date: Date.today).count
end
```

---

## Active Record Encryption

### Setup

```bash
rails db:encryption:init
# Generates config/credentials/encryption.yml with primary_key, deterministic_key, key_derivation_salt
```

### Usage

```ruby
class User < ApplicationRecord
  encrypts :email, deterministic: true   # searchable via exact match
  encrypts :ssn                          # non-deterministic (more secure, not searchable)
  encrypts :medical_notes, downcase: true
end

# Queries work transparently for deterministic attributes:
User.find_by(email: "user@example.com")  # encrypted search

# Key rotation:
class User < ApplicationRecord
  encrypts :email, deterministic: true, previous: [
    { deterministic: true, key_provider: OldKeyProvider.new }
  ]
end
```

### Configuration

```ruby
# config/application.rb
config.active_record.encryption.primary_key = Rails.application.credentials.dig(:active_record_encryption, :primary_key)
config.active_record.encryption.deterministic_key = Rails.application.credentials.dig(:active_record_encryption, :deterministic_key)
config.active_record.encryption.key_derivation_salt = Rails.application.credentials.dig(:active_record_encryption, :key_derivation_salt)
config.active_record.encryption.extend_queries = true  # enable querying encrypted columns
```

---

## Action Text

### Setup

```bash
rails action_text:install
rails db:migrate
```

### Model integration

```ruby
class Article < ApplicationRecord
  has_rich_text :body
  has_rich_text :summary

  # Eager-load to avoid N+1:
  scope :with_rich_texts, -> { with_rich_text_body.with_rich_text_summary }
end
```

### Form usage

```erb
<%= form_with model: @article do |f| %>
  <%= f.rich_text_area :body %>
<% end %>
```

### Content querying and sanitization

```ruby
article.body.to_plain_text        # strip HTML
article.body.to_trix_html         # Trix-compatible HTML
article.body.blank?               # check for empty content

# Custom sanitization:
class Article < ApplicationRecord
  has_rich_text :body
  before_save :sanitize_body

  private
  def sanitize_body
    self.body = ActionText::Content.new(body.to_html).to_html if body.present?
  end
end
```

---

## Action Mailbox

### Setup

```bash
rails action_mailbox:install
rails db:migrate
```

### Routing inbound email

```ruby
# app/mailboxes/application_mailbox.rb
class ApplicationMailbox < ActionMailbox::Base
  routing /support@/i    => :support
  routing /reply-(.+)@/i => :replies
  routing :all           => :catch_all
end
```

### Processing

```ruby
# app/mailboxes/support_mailbox.rb
class SupportMailbox < ApplicationMailbox
  before_processing :ensure_user_exists

  def process
    Ticket.create!(
      user: user,
      subject: mail.subject,
      body: mail.decoded,
      attachments: extract_attachments
    )
  end

  private

  def user
    @user ||= User.find_by(email: mail.from_address.to_s)
  end

  def ensure_user_exists
    bounced! unless user
  end

  def extract_attachments
    mail.attachments.map do |attachment|
      { io: StringIO.new(attachment.decoded), filename: attachment.filename,
        content_type: attachment.content_type }
    end
  end
end
```

---

## Composite Primary Keys

Rails 7.1+ supports composite primary keys natively:

```ruby
# Migration
class CreateTravelRoutes < ActiveRecord::Migration[8.0]
  def change
    create_table :travel_routes, primary_key: [:origin, :destination] do |t|
      t.string :origin, null: false
      t.string :destination, null: false
      t.integer :distance
      t.timestamps
    end
  end
end

# Model
class TravelRoute < ApplicationRecord
  self.primary_key = [:origin, :destination]

  # Query by composite key:
  # TravelRoute.find(["NYC", "LAX"])
end
```

### Composite foreign keys

```ruby
class Booking < ApplicationRecord
  belongs_to :travel_route, query_constraints: [:origin, :destination]
end

class TravelRoute < ApplicationRecord
  self.primary_key = [:origin, :destination]
  has_many :bookings, query_constraints: [:origin, :destination]
end
```

---

## Async Queries

Load multiple queries in parallel to reduce latency:

```ruby
class DashboardController < ApplicationController
  def show
    @recent_articles = Article.published.recent.load_async
    @popular_tags    = Tag.popular.limit(20).load_async
    @user_stats      = User.active.count_async
    @pending_reviews = Review.pending.load_async
    # All 4 queries fire concurrently.
    # Accessing results blocks until that specific query completes.
  end
end
```

### Configuration

```ruby
# config/application.rb
config.active_record.async_query_executor = :global_thread_pool
# or :multi_thread_pool for per-database pools

config.active_record.global_executor_concurrency = 4
```

### Aggregate async methods

```ruby
Article.published.count_async    # => Promise<Integer>
Article.published.sum_async(:views)
Article.published.minimum_async(:created_at)
Article.published.maximum_async(:updated_at)
```

---

## Strict Loading

Prevent lazy loading (N+1) at various levels:

```ruby
# Per-query:
articles = Article.strict_loading.includes(:author)
articles.first.comments  # => raises ActiveRecord::StrictLoadingViolationError

# Per-association:
class Article < ApplicationRecord
  has_many :comments, strict_loading: true
end

# Per-record:
article = Article.find(1)
article.strict_loading!
article.comments  # => raises error

# App-wide (development/test):
# config/environments/development.rb
config.active_record.strict_loading_by_default = true

# Disable for specific query:
Article.strict_loading(false).find(1)
```

### Strict loading mode

```ruby
# :all (default) — raises on any lazy load
# :n_plus_one_only — only raises when lazy-loading a collection (allows singular)
class Article < ApplicationRecord
  self.strict_loading_mode = :n_plus_one_only
end
```

---

## Query Logs

Tag SQL queries with source context for debugging:

```ruby
# config/application.rb
config.active_record.query_log_tags_enabled = true
config.active_record.query_log_tags = [
  :application, :controller, :action, :job,
  { request_id: ->(context) { context[:controller]&.request&.request_id } },
  { source_location: ActiveRecord::QueryLogs::Source.new }
]
config.active_record.query_log_tags_format = :sqlcommenter
```

Output: SQL comments appended to every query:

```sql
SELECT * FROM articles /*application='MyApp',controller='articles',action='index'*/
```

---

## Horizontal Sharding

### Configuration

```yaml
# config/database.yml
production:
  primary:
    <<: *default
    database: myapp_primary
  shard_one:
    <<: *default
    database: myapp_shard_1
  shard_two:
    <<: *default
    database: myapp_shard_2
```

### Model setup

```ruby
class ShardedRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to shards: {
    default: { writing: :primary },
    shard_one: { writing: :shard_one },
    shard_two: { writing: :shard_two }
  }
end
```

### Shard selection middleware

```ruby
# app/middleware/shard_selector.rb
class ShardSelector
  def initialize(app)
    @app = app
  end

  def call(env)
    request = ActionDispatch::Request.new(env)
    tenant = Tenant.find_by!(subdomain: request.subdomain)
    ActiveRecord::Base.connected_to(shard: tenant.shard.to_sym) do
      @app.call(env)
    end
  end
end

# config/application.rb
config.middleware.use ShardSelector
```

### Manual shard switching

```ruby
ActiveRecord::Base.connected_to(shard: :shard_one) do
  User.create!(name: "Tenant User")
end
```

---

## Turbo Streams Advanced

### Custom Turbo Stream actions

```ruby
# app/helpers/turbo_stream_actions_helper.rb
module TurboStreamActionsHelper
  def redirect_to(url)
    turbo_stream_action_tag :redirect, url: url
  end

  def notification(message, type: :info)
    turbo_stream_action_tag :notification, message: message, type: type
  end
end
Turbo::Streams::TagBuilder.prepend(TurboStreamActionsHelper)
```

```javascript
// app/javascript/custom_actions.js
import { StreamActions } from "@hotwired/turbo"

StreamActions.redirect = function () {
  Turbo.visit(this.getAttribute("url"))
}

StreamActions.notification = function () {
  const message = this.getAttribute("message")
  const type = this.getAttribute("type")
  // Show toast notification
  document.dispatchEvent(new CustomEvent("notification", { detail: { message, type } }))
}
```

### Broadcasting from models

```ruby
class Message < ApplicationRecord
  belongs_to :room
  after_create_commit -> { broadcast_append_to room, target: "messages" }
  after_update_commit -> { broadcast_replace_to room }
  after_destroy_commit -> { broadcast_remove_to room }
end
```

### Morph streams (Rails 8)

```ruby
class Article < ApplicationRecord
  broadcasts_refreshes_to :author  # morphs page instead of replacing
end
```

### Multi-target broadcasting

```erb
<%= turbo_stream.append "notifications", partial: "notification", locals: { msg: @msg } %>
<%= turbo_stream.update "unread_count", html: current_user.unread_count.to_s %>
<%= turbo_stream.remove dom_id(@old_item) %>
```

---

## Stimulus Controller Composition

### Mixin pattern via JavaScript modules

```javascript
// app/javascript/mixins/debounce.js
export const Debounce = (superclass) => class extends superclass {
  debounce(func, wait = 300) {
    let timeout
    return (...args) => {
      clearTimeout(timeout)
      timeout = setTimeout(() => func.apply(this, args), wait)
    }
  }
}

// app/javascript/controllers/search_controller.js
import { Controller } from "@hotwired/stimulus"
import { Debounce } from "../mixins/debounce"

export default class extends Debounce(Controller) {
  static targets = ["input", "results"]

  connect() {
    this.search = this.debounce(this.performSearch.bind(this))
  }

  performSearch() {
    const query = this.inputTarget.value
    fetch(`/search?q=${encodeURIComponent(query)}`)
      .then(r => r.text())
      .then(html => { this.resultsTarget.innerHTML = html })
  }
}
```

### Outlets — controller-to-controller communication

```html
<!-- parent declares outlet to child controller -->
<div data-controller="form" data-form-validation-outlet=".validator">
  <div class="validator" data-controller="validation">
    <input data-action="input->form#validate">
  </div>
</div>
```

```javascript
// form_controller.js
import { Controller } from "@hotwired/stimulus"
export default class extends Controller {
  static outlets = ["validation"]

  validate() {
    this.validationOutlets.forEach(v => v.run())
  }
}

// validation_controller.js
import { Controller } from "@hotwired/stimulus"
export default class extends Controller {
  run() {
    // perform validation
  }
}
```

### Values API for reactive state

```javascript
import { Controller } from "@hotwired/stimulus"
export default class extends Controller {
  static values = { count: { type: Number, default: 0 }, open: Boolean }

  increment() { this.countValue++ }

  countValueChanged(value, previousValue) {
    this.element.querySelector("[data-count]").textContent = value
  }

  openValueChanged() {
    this.element.classList.toggle("expanded", this.openValue)
  }
}
```
