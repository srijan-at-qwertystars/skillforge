#!/usr/bin/env bash
# setup-rails.sh — Generate a new Rails app with production-ready configuration
#
# Usage:
#   ./setup-rails.sh <app_name> [options]
#
# Options:
#   --api          API-only mode (no views/assets)
#   --db=DB        Database adapter (postgresql|mysql|sqlite3, default: postgresql)
#   --css=CSS      CSS framework (tailwind|bootstrap, default: tailwind)
#   --skip-docker  Skip Docker/Kamal setup
#
# Examples:
#   ./setup-rails.sh myapp
#   ./setup-rails.sh myapi --api --db=postgresql
#   ./setup-rails.sh myapp --css=bootstrap --skip-docker

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
APP_NAME="${1:-}"
API_MODE=false
DB="postgresql"
CSS="tailwind"
SKIP_DOCKER=false

# ── Parse args ────────────────────────────────────────────────────────────────
if [[ -z "$APP_NAME" ]]; then
  echo "Usage: $0 <app_name> [--api] [--db=DB] [--css=CSS] [--skip-docker]"
  exit 1
fi
shift

for arg in "$@"; do
  case "$arg" in
    --api)          API_MODE=true ;;
    --db=*)         DB="${arg#*=}" ;;
    --css=*)        CSS="${arg#*=}" ;;
    --skip-docker)  SKIP_DOCKER=true ;;
    *)              echo "Unknown option: $arg"; exit 1 ;;
  esac
done

# ── Preflight checks ─────────────────────────────────────────────────────────
echo "🔍 Checking prerequisites..."

for cmd in ruby gem; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ $cmd not found. Install Ruby first."
    exit 1
  fi
done

RUBY_VERSION=$(ruby -e "puts RUBY_VERSION")
RUBY_MAJOR=$(echo "$RUBY_VERSION" | cut -d. -f1)
RUBY_MINOR=$(echo "$RUBY_VERSION" | cut -d. -f2)
if (( RUBY_MAJOR < 3 || (RUBY_MAJOR == 3 && RUBY_MINOR < 2) )); then
  echo "❌ Ruby >= 3.2 required (found $RUBY_VERSION)"
  exit 1
fi

if ! gem list -i rails &>/dev/null; then
  echo "📦 Installing Rails..."
  gem install rails --no-document
fi

echo "✅ Ruby $RUBY_VERSION, Rails $(rails -v)"

# ── Generate app ──────────────────────────────────────────────────────────────
echo ""
echo "🚀 Generating Rails app: $APP_NAME"
RAILS_OPTS="--database=$DB --skip-jbuilder"

if $API_MODE; then
  RAILS_OPTS="$RAILS_OPTS --api --skip-asset-pipeline"
else
  RAILS_OPTS="$RAILS_OPTS --css=$CSS"
fi

if $SKIP_DOCKER; then
  RAILS_OPTS="$RAILS_OPTS --skip-docker"
fi

# shellcheck disable=SC2086
rails new "$APP_NAME" $RAILS_OPTS

cd "$APP_NAME"

# ── Add recommended gems ─────────────────────────────────────────────────────
echo ""
echo "📦 Adding recommended gems..."

cat >> Gemfile <<'GEMS'

# ── Performance & Monitoring ──
gem "rack-mini-profiler"

# ── Security ──
gem "bundler-audit", require: false
gem "brakeman", require: false

# ── Background Jobs (Rails 8 default) ──
# gem "solid_queue" # already included in Rails 8

# ── Pagination ──
gem "pagy"

# ── Authorization ──
gem "pundit"

group :development do
  gem "bullet"          # N+1 query detection
  gem "annotate"        # schema annotations on models
  gem "strong_migrations" # catch unsafe migrations
  gem "letter_opener"   # preview emails in browser
  gem "rubocop-rails-omakase", require: false
end

group :development, :test do
  gem "factory_bot_rails"
  gem "faker"
  gem "rspec-rails"
  gem "shoulda-matchers"
end

group :test do
  gem "capybara"
  gem "selenium-webdriver"
  gem "simplecov", require: false
end
GEMS

bundle install

# ── Configure Bullet (N+1 detection) ─────────────────────────────────────────
echo ""
echo "⚙️  Configuring Bullet..."
cat >> config/environments/development.rb <<'BULLET'

  # Bullet N+1 detection
  config.after_initialize do
    Bullet.enable = true
    Bullet.alert = true
    Bullet.bullet_logger = true
    Bullet.rails_logger = true
    Bullet.add_footer = true
  end
BULLET

# ── Install RSpec ─────────────────────────────────────────────────────────────
echo ""
echo "🧪 Setting up RSpec..."
bundle exec rails generate rspec:install 2>/dev/null || true

if [[ -f spec/rails_helper.rb ]]; then
  cat >> spec/rails_helper.rb <<'RSPEC'

Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :rails
  end
end

RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods
end
RSPEC
fi

# ── Install Pundit ────────────────────────────────────────────────────────────
echo ""
echo "🔐 Setting up Pundit..."
bundle exec rails generate pundit:install 2>/dev/null || true

# ── Setup database ────────────────────────────────────────────────────────────
echo ""
echo "🗄️  Setting up database..."
if bin/rails db:create 2>/dev/null; then
  bin/rails db:migrate
  echo "✅ Database created and migrated"
else
  echo "⚠️  Database creation skipped (configure config/database.yml)"
fi

# ── Generate authentication (Rails 8) ────────────────────────────────────────
echo ""
read -r -p "🔑 Generate Rails 8 authentication scaffold? [y/N] " response
if [[ "$response" =~ ^[Yy]$ ]]; then
  bin/rails generate authentication
  bin/rails db:migrate
  echo "✅ Authentication generated"
fi

# ── Create useful directories ─────────────────────────────────────────────────
mkdir -p app/services app/queries app/presenters app/policies

# ── Create base service object ────────────────────────────────────────────────
cat > app/services/application_service.rb <<'SERVICE'
class ApplicationService
  def self.call(...)
    new(...).call
  end
end
SERVICE

# ── Git init ──────────────────────────────────────────────────────────────────
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  git init
  git add -A
  git commit -m "Initial commit: Rails app with production config"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "✅ $APP_NAME is ready!"
echo ""
echo "  cd $APP_NAME"
echo "  bin/rails server"
echo ""
echo "Included:"
echo "  • Database:       $DB"
[[ "$API_MODE" == false ]] && echo "  • CSS:            $CSS"
echo "  • Testing:        RSpec + FactoryBot + Shoulda"
echo "  • N+1 detection:  Bullet"
echo "  • Authorization:  Pundit"
echo "  • Code quality:   RuboCop (omakase), Brakeman, bundler-audit"
echo "  • Pagination:     Pagy"
echo "  • App structure:  services/ queries/ presenters/ policies/"
echo "═══════════════════════════════════════════════════════"
