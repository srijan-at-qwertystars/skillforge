# Rails Troubleshooting Guide

> Diagnosis and fixes for common Rails 7.x/8.x issues. Each section: symptom → cause → fix.

## Table of Contents

- [N+1 Queries](#n1-queries)
- [Slow Migrations](#slow-migrations)
- [Memory Bloat](#memory-bloat)
- [Asset Pipeline vs Propshaft Migration](#asset-pipeline-vs-propshaft-migration)
- [Zeitwerk Autoloading Errors](#zeitwerk-autoloading-errors)
- [ActiveRecord Connection Pool Exhaustion](#activerecord-connection-pool-exhaustion)
- [CSRF Token Issues in API Mode](#csrf-token-issues-in-api-mode)
- [Turbo Frame / Stream Debugging](#turbo-frame--stream-debugging)
- [Rails 7 → 8 Upgrade Guide](#rails-7--8-upgrade-guide)

---

## N+1 Queries

### Symptom
Slow pages, log shows repeated `SELECT` for associated records.

### Detection with Bullet

```ruby
# Gemfile
gem "bullet", group: :development

# config/environments/development.rb
config.after_initialize do
  Bullet.enable        = true
  Bullet.alert         = true    # JS alert in browser
  Bullet.bullet_logger = true    # log/bullet.log
  Bullet.rails_logger  = true    # Rails log
  Bullet.add_footer    = true    # page footer
  Bullet.raise         = false   # set true in test env to fail tests
end

# config/environments/test.rb
config.after_initialize do
  Bullet.enable = true
  Bullet.raise  = true  # fail tests on N+1
end
```

### Fixes

```ruby
# 1. includes — lets Rails choose preload or eager_load
Article.includes(:author, :tags).where(published: true)

# 2. preload — always separate queries (good for large associations)
Article.preload(:comments).limit(50)

# 3. eager_load — LEFT OUTER JOIN (needed for WHERE on associations)
Article.eager_load(:author).where(authors: { active: true })

# 4. Nested eager loading
Article.includes(author: :profile, comments: [:user, :reactions])

# 5. strict_loading to catch N+1 in development
Article.strict_loading.find(params[:id])
```

### Counter caches (avoid COUNT N+1)

```ruby
# Migration
add_column :articles, :comments_count, :integer, default: 0, null: false

# Model
class Comment < ApplicationRecord
  belongs_to :article, counter_cache: true
end

# Reset: Article.find_each { |a| Article.reset_counters(a.id, :comments) }
```

---

## Slow Migrations

### Problem: Migration locks table for too long

```ruby
# BAD — locks table while adding index
class AddIndexToUsers < ActiveRecord::Migration[8.0]
  def change
    add_index :users, :email  # locks entire table on large tables
  end
end

# GOOD — concurrent index (PostgreSQL)
class AddIndexToUsers < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :users, :email, algorithm: :concurrently
  end
end
```

### Large data migrations

```ruby
# BAD — loads all records into memory
User.all.each { |u| u.update!(normalized_email: u.email.downcase) }

# GOOD — batched updates
User.in_batches(of: 1000) do |batch|
  batch.update_all("normalized_email = LOWER(email)")
end

# BETTER — background migration (for very large tables)
class BackfillNormalizedEmail < ActiveRecord::Migration[8.0]
  def up
    # Run in background job instead of blocking deploy
    BackfillEmailJob.perform_later
  end
end
```

### Safe migration checklist

| Operation | Risk | Safe Alternative |
|-----------|------|-----------------|
| `add_index` | Table lock | `algorithm: :concurrently` + `disable_ddl_transaction!` |
| `add_column` with default | Table rewrite (PG < 11) | Add column, then set default separately |
| `remove_column` | Breaks running code | Deploy code ignoring column first, then remove |
| `rename_column` | Breaks running code | Add new column, backfill, deploy code, drop old |
| `change_column_null` | Full table scan | Use `validate: false`, validate separately |
| Large data updates | Long lock/transaction | `in_batches` or background jobs |

Use `strong_migrations` gem for automated safety checks:

```ruby
gem "strong_migrations"
```

---

## Memory Bloat

### Diagnosis

```ruby
# Add to Gemfile
gem "derailed_benchmarks", group: :development
gem "memory_profiler", group: :development

# CLI
bundle exec derailed bundle:mem  # memory used by gems
bundle exec derailed exec perf:mem  # memory per request
```

### Common causes and fixes

```ruby
# 1. Loading too many records
# BAD:
users = User.all.map(&:email)
# GOOD:
users = User.pluck(:email)

# 2. Not using find_each for iteration
# BAD: User.all.each { ... }  — loads ALL records
# GOOD:
User.find_each(batch_size: 500) { |user| process(user) }

# 3. String accumulation in loops
# BAD:
result = ""
items.each { |i| result += i.to_s }
# GOOD:
result = items.map(&:to_s).join

# 4. Caching too much
# Review cache sizes — use LRU eviction or TTLs
Rails.cache.fetch("key", expires_in: 1.hour) { expensive_query }

# 5. Gem bloat — audit with:
bundle exec derailed bundle:mem
# Remove or lazy-load heavy gems
```

### Puma worker killer

```ruby
# Gemfile
gem "puma_worker_killer"

# config/puma.rb
before_fork do
  PumaWorkerKiller.enable_rolling_restart(12 * 3600) # restart every 12h
  PumaWorkerKiller.config do |config|
    config.ram           = 1024  # MB limit
    config.frequency     = 30    # check every 30s
    config.percent_usage = 0.90
  end
  PumaWorkerKiller.start
end
```

---

## Asset Pipeline vs Propshaft Migration

### When to migrate
- New Rails 8 apps use Propshaft by default
- Migrate if: you don't need Sprockets preprocessors (Sass compilation, CoffeeScript)
- Stay with Sprockets if: you rely on custom preprocessors or `//= require` directives

### Migration steps

```ruby
# 1. Replace gems in Gemfile
# Remove:
gem "sprockets-rails"
gem "sass-rails"
# Add:
gem "propshaft"
gem "dartsass-rails"  # if you need Sass

# 2. Remove Sprockets config
# Delete config/initializers/assets.rb
# Remove any `//= require` directives from application.js/css

# 3. Update asset references
# Sprockets:  asset_path("image.png")
# Propshaft:  same helper, but no fingerprinting in dev

# 4. Move assets
# Propshaft looks in app/assets/ — same location
# Remove any vendor/assets or lib/assets references

# 5. Update manifest
# Propshaft uses .manifest.json (auto-generated), no manifest.js needed
# Delete app/assets/config/manifest.js

# 6. CSS bundling (if using cssbundling-rails)
# No changes needed — cssbundling works with both

# 7. Test
rails assets:precompile
rails server  # verify all assets load
```

### Key differences

| Feature | Sprockets | Propshaft |
|---------|-----------|-----------|
| Preprocessing | Built-in (Sass, Coffee) | External (dartsass-rails) |
| `//= require` directives | Yes | No |
| Fingerprinting | Yes (dev + prod) | Prod only |
| Source maps | Plugin | Native |
| Speed | Slower | Faster |
| Import maps | Separate gem | Built-in compatible |

---

## Zeitwerk Autoloading Errors

### Common errors

**`NameError: expected file app/models/user_profile.rb to define UserProfile`**

Fix: file name must match constant. `user_profile.rb` → `UserProfile`.

**`Zeitwerk::NameError: expected file app/models/api/client.rb to define Api::Client`**

Fix: directory name must match module. `api/` → `Api` (not `API`).

### Acronym configuration

```ruby
# config/initializers/inflections.rb
ActiveSupport::Inflector.inflections(:en) do |inflect|
  inflect.acronym "API"
  inflect.acronym "SMS"
  inflect.acronym "HTML"
end
# Now: app/models/api/client.rb → API::Client
# And: app/services/sms_sender.rb → SMSSender
```

### Debugging

```bash
# Validate all autoloaded files
bin/rails zeitwerk:check

# See what's loaded
bin/rails runner "pp Rails.autoloaders.main.dirs"

# Eager load everything (find issues)
bin/rails runner "Rails.application.eager_load!"
```

### Common gotchas

```ruby
# 1. Concerns must be in a concerns/ directory
# app/models/concerns/searchable.rb → Searchable (module)

# 2. Don't use require/require_relative for autoloaded code
# BAD: require_relative "../models/user"
# Zeitwerk handles it automatically

# 3. STI models must match file names
# app/models/vehicles/car.rb → Vehicles::Car
# NOT app/models/vehicle.rb with class Car < Vehicle inside

# 4. Collapsed directories (Rails 7+)
# config/initializers/zeitwerk.rb
Rails.autoloaders.main.collapse("#{Rails.root}/app/models/concerns")
```

---

## ActiveRecord Connection Pool Exhaustion

### Symptom
`ActiveRecord::ConnectionTimeoutError` or requests hanging under load.

### Diagnosis

```ruby
# Check pool stats
ActiveRecord::Base.connection_pool.stat
# => { size: 5, connections: 5, busy: 5, dead: 0, idle: 0, waiting: 3, checkout_timeout: 5 }

# Monitor in production
ActiveSupport::Notifications.subscribe("!connection.active_record") do |event|
  pool = ActiveRecord::Base.connection_pool
  Rails.logger.warn("Pool exhaustion risk") if pool.stat[:waiting] > 0
end
```

### Fix: size pool correctly

```yaml
# config/database.yml
production:
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  checkout_timeout: 5
  reaping_frequency: 10
```

**Rule: pool >= Puma threads per worker**

```ruby
# config/puma.rb
threads_count = ENV.fetch("RAILS_MAX_THREADS", 5).to_i
threads threads_count, threads_count
workers ENV.fetch("WEB_CONCURRENCY", 2).to_i
# Each worker gets its own pool, so pool = threads_count
```

### Common causes

| Cause | Fix |
|-------|-----|
| Pool too small | Increase `pool` in database.yml |
| Leaked connections | Use `reaping_frequency` config |
| Background threads using AR | Wrap in `ActiveRecord::Base.connection_pool.with_connection { }` |
| Too many Puma threads | Match pool size to thread count |
| Slow queries holding connections | Add query timeouts, optimize queries |

---

## CSRF Token Issues in API Mode

### Problem
`ActionController::InvalidAuthenticityToken` in API mode, or CSRF missing for hybrid apps.

### API-only apps (no CSRF needed)

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::API
  # No CSRF by default in API mode — use token auth instead
end
```

### Hybrid apps (API + web)

```ruby
class ApplicationController < ActionController::Base
  protect_from_forgery with: :exception
end

class Api::BaseController < ActionController::Base
  # Skip CSRF for API, use token auth
  skip_forgery_protection
  before_action :authenticate_api_token!

  private
  def authenticate_api_token!
    token = request.headers["Authorization"]&.remove("Bearer ")
    head :unauthorized unless ApiToken.active.exists?(token: token)
  end
end
```

### Turbo/Hotwire CSRF

```erb
<%# Rails meta tags provide CSRF token for Turbo automatically %>
<%= csrf_meta_tags %>

<%# For fetch/AJAX requests, include token: %>
<script>
  const token = document.querySelector('meta[name="csrf-token"]')?.content;
  fetch("/endpoint", {
    method: "POST",
    headers: { "X-CSRF-Token": token, "Content-Type": "application/json" },
    body: JSON.stringify(data)
  });
</script>
```

---

## Turbo Frame / Stream Debugging

### Frame not loading

```erb
<%# 1. Ensure matching IDs %>
<%# Page A (source): %>
<%= turbo_frame_tag "article_1" do %>
  <%= link_to "Edit", edit_article_path(@article) %>
<% end %>

<%# Page B (target) must have same frame ID: %>
<%= turbo_frame_tag "article_1" do %>
  <%= render "form", article: @article %>
<% end %>

<%# 2. If frame content is empty, check: %>
<%# - Target page actually wraps content in matching turbo_frame_tag %>
<%# - No redirect breaking the frame (use data-turbo-frame="_top" for redirects) %>
```

### Stream not updating

```ruby
# 1. Verify WebSocket connection
# Browser console: Turbo.connectStreamSource and check ActionCable connection

# 2. Check broadcast target matches DOM ID
# Model:
after_create_commit -> { broadcast_append_to "messages", target: "messages_list" }
# View must have: <div id="messages_list">

# 3. Verify ActionCable subscription
# Browser console:
# ActionCable.consumer.subscriptions.subscriptions
```

### Debug tools

```ruby
# Enable Turbo debug mode
# app/javascript/application.js
import { Turbo } from "@hotwired/turbo-rails"
Turbo.setProgressBarDelay(0)
// In browser console: Turbo.session.logLevel = "debug"

# Server-side: log Turbo responses
class ApplicationController < ActionController::Base
  after_action :log_turbo_response

  private
  def log_turbo_response
    if request.headers["Turbo-Frame"]
      Rails.logger.debug "Turbo-Frame: #{request.headers['Turbo-Frame']}"
      Rails.logger.debug "Response: #{response.content_type}"
    end
  end
end
```

### Common frame/stream gotchas

| Issue | Fix |
|-------|-----|
| Frame shows "Content missing" | Target page missing matching `turbo_frame_tag` |
| Link breaks out of frame | Add `data-turbo-frame="_top"` |
| Form submission doesn't update | Return `turbo_stream` format or ensure frame wraps response |
| Stream append duplicates | Use `broadcast_replace_to` instead, or set unique DOM IDs |
| Flash messages lost | Render flash in a Turbo Stream response |

---

## Rails 7 → 8 Upgrade Guide

### Pre-upgrade checklist

```bash
# 1. Ensure on latest Rails 7.2.x
bundle update rails
bin/rails app:update

# 2. Fix all deprecation warnings
RAILS_ENV=test bin/rails test 2>&1 | grep -i deprecat

# 3. Ensure Ruby >= 3.2 (Rails 8 requirement)
ruby -v

# 4. Audit gems for Rails 8 compatibility
bundle outdated
bundle exec bundler-audit check
```

### Upgrade steps

```bash
# 1. Update Gemfile
gem "rails", "~> 8.0"

# 2. Bundle update
bundle update rails

# 3. Run update task
bin/rails app:update
# Review each file diff carefully — keep your customizations

# 4. Update framework defaults
# config/application.rb
config.load_defaults 8.0
```

### Breaking changes in Rails 8

| Change | Action |
|--------|--------|
| Propshaft is default | Migrate from Sprockets or keep with explicit gem |
| Solid Queue replaces Sidekiq as default | Update job config or keep Sidekiq |
| Solid Cache/Cable | Update cache/cable config or keep Redis |
| Kamal 2 for deployment | Optional — adopt or keep existing deploy |
| `params.expect` preferred | Replace `params.require.permit` gradually |
| `schema.rb` columns alphabetized | Expect large schema.rb diff (cosmetic only) |
| `Rails.application.credentials` | Verify encryption key compatibility |
| Zeitwerk strictly enforced | Run `bin/rails zeitwerk:check` |
| `config.autoload_lib` | Set up in `config/application.rb` |
| Authentication generator | Optional — `rails g authentication` |

### Post-upgrade validation

```bash
# Run full test suite
bin/rails test
bundle exec rspec  # if using RSpec

# Check routes
bin/rails routes

# Verify autoloading
bin/rails zeitwerk:check

# Check for remaining deprecations
grep -r "DEPRECATION" log/test.log

# Verify assets
bin/rails assets:precompile

# Test in staging before production deploy
```

### Adopting Rails 8 defaults incrementally

```ruby
# config/application.rb — adopt one at a time:
# config.load_defaults 8.0

# Or cherry-pick:
config.active_record.default_column_serializer = nil  # Rails 8 default
config.active_support.to_time_preserves_timezone = :zone
config.action_controller.allow_deprecated_parameters_hash_equality = false
```
