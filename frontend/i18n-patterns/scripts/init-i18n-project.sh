#!/usr/bin/env bash
# =============================================================================
# init-i18n-project.sh — Set up i18n in a React or Next.js project
#
# Usage:
#   ./init-i18n-project.sh [--framework react|nextjs] [--locales en,fr,de,ja]
#
# Examples:
#   ./init-i18n-project.sh                          # defaults: react, en,fr,de,ja
#   ./init-i18n-project.sh --framework nextjs       # Next.js with next-intl
#   ./init-i18n-project.sh --locales en,es,pt-BR    # custom locales
#
# What it does:
#   1. Detects package manager (npm/yarn/pnpm)
#   2. Installs i18n dependencies
#   3. Creates locale file directory structure
#   4. Generates base translation files (en as source)
#   5. Creates i18n configuration file
#   6. Adds string extraction script to package.json
#   7. Prints next steps
# =============================================================================
set -euo pipefail

# --- Defaults ---
FRAMEWORK="react"
LOCALES="en,fr,de,ja"
DEFAULT_LOCALE="en"

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --framework)
      FRAMEWORK="$2"
      shift 2
      ;;
    --locales)
      LOCALES="$2"
      shift 2
      ;;
    --help|-h)
      head -20 "$0" | tail -18
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

IFS=',' read -ra LOCALE_ARRAY <<< "$LOCALES"
DEFAULT_LOCALE="${LOCALE_ARRAY[0]}"

# --- Detect package manager ---
detect_pm() {
  if [ -f "pnpm-lock.yaml" ]; then echo "pnpm"
  elif [ -f "yarn.lock" ]; then echo "yarn"
  else echo "npm"
  fi
}

PM=$(detect_pm)
echo "📦 Package manager: $PM"
echo "🌍 Framework: $FRAMEWORK"
echo "🗣️  Locales: ${LOCALE_ARRAY[*]} (default: $DEFAULT_LOCALE)"
echo ""

# --- Install dependencies ---
install_deps() {
  local deps=("$@")
  case $PM in
    pnpm) pnpm add "${deps[@]}" ;;
    yarn) yarn add "${deps[@]}" ;;
    *)    npm install "${deps[@]}" ;;
  esac
}

install_dev_deps() {
  local deps=("$@")
  case $PM in
    pnpm) pnpm add -D "${deps[@]}" ;;
    yarn) yarn add -D "${deps[@]}" ;;
    *)    npm install -D "${deps[@]}" ;;
  esac
}

echo "📥 Installing dependencies..."

if [ "$FRAMEWORK" = "nextjs" ]; then
  install_deps next-intl
  echo "✅ Installed next-intl"
else
  install_deps i18next react-i18next i18next-http-backend i18next-browser-languagedetector
  install_dev_deps i18next-parser
  echo "✅ Installed react-i18next and related packages"
fi

# --- Create directory structure ---
echo ""
echo "📁 Creating locale directory structure..."

if [ "$FRAMEWORK" = "nextjs" ]; then
  LOCALE_DIR="messages"
  mkdir -p "$LOCALE_DIR"
  mkdir -p "i18n"

  for locale in "${LOCALE_ARRAY[@]}"; do
    cat > "$LOCALE_DIR/$locale.json" << JSONEOF
{
  "common": {
    "siteName": "MyApp",
    "nav": {
      "home": "Home",
      "about": "About"
    },
    "actions": {
      "save": "Save",
      "cancel": "Cancel",
      "delete": "Delete",
      "loading": "Loading..."
    }
  },
  "home": {
    "title": "Welcome to {siteName}",
    "description": "Your application description here."
  },
  "errors": {
    "notFound": "Page not found",
    "generic": "Something went wrong. Please try again."
  }
}
JSONEOF
    echo "  ✅ $LOCALE_DIR/$locale.json"
  done
else
  LOCALE_DIR="public/locales"
  NAMESPACES=("common" "auth" "errors")

  for locale in "${LOCALE_ARRAY[@]}"; do
    mkdir -p "$LOCALE_DIR/$locale"
    for ns in "${NAMESPACES[@]}"; do
      case $ns in
        common)
          cat > "$LOCALE_DIR/$locale/$ns.json" << JSONEOF
{
  "appName": "MyApp",
  "nav": {
    "home": "Home",
    "about": "About",
    "settings": "Settings"
  },
  "actions": {
    "save": "Save",
    "cancel": "Cancel",
    "delete": "Delete",
    "confirm": "Confirm",
    "loading": "Loading..."
  },
  "pagination": {
    "previous": "Previous",
    "next": "Next",
    "page": "Page {current} of {total}"
  }
}
JSONEOF
          ;;
        auth)
          cat > "$LOCALE_DIR/$locale/$ns.json" << JSONEOF
{
  "login": {
    "title": "Sign In",
    "email": "Email address",
    "password": "Password",
    "submit": "Log In",
    "forgotPassword": "Forgot password?",
    "noAccount": "Don't have an account? <link>Sign up</link>"
  },
  "logout": {
    "button": "Log Out",
    "confirm": "Are you sure you want to log out?"
  }
}
JSONEOF
          ;;
        errors)
          cat > "$LOCALE_DIR/$locale/$ns.json" << JSONEOF
{
  "generic": "Something went wrong. Please try again.",
  "network": "Unable to connect. Check your internet connection.",
  "notFound": "The page you're looking for doesn't exist.",
  "unauthorized": "Please log in to continue.",
  "validation": {
    "required": "This field is required.",
    "email": "Please enter a valid email address.",
    "minLength": "Must be at least {min} characters."
  }
}
JSONEOF
          ;;
      esac
    done
    echo "  ✅ $LOCALE_DIR/$locale/ (${NAMESPACES[*]})"
  done
fi

# --- Generate configuration ---
echo ""
echo "⚙️  Generating i18n configuration..."

if [ "$FRAMEWORK" = "nextjs" ]; then
  # Create routing config
  LOCALE_LIST=$(printf "'%s', " "${LOCALE_ARRAY[@]}" | sed 's/, $//')
  cat > "i18n/routing.ts" << TSEOF
import { defineRouting } from 'next-intl/routing';

export const routing = defineRouting({
  locales: [$LOCALE_LIST],
  defaultLocale: '$DEFAULT_LOCALE',
  localePrefix: 'as-needed',
});

export type Locale = (typeof routing.locales)[number];
TSEOF

  # Create request config
  cat > "i18n/request.ts" << 'TSEOF'
import { getRequestConfig } from 'next-intl/server';
import { routing } from './routing';

export default getRequestConfig(async ({ requestLocale }) => {
  let locale = await requestLocale;
  if (!locale || !routing.locales.includes(locale as any)) {
    locale = routing.defaultLocale;
  }
  return {
    locale,
    messages: (await import(`../messages/${locale}.json`)).default,
  };
});
TSEOF

  # Create navigation helpers
  cat > "i18n/navigation.ts" << 'TSEOF'
import { createNavigation } from 'next-intl/navigation';
import { routing } from './routing';

export const { Link, redirect, usePathname, useRouter, getPathname } =
  createNavigation(routing);
TSEOF

  # Create middleware
  cat > "middleware.ts" << 'TSEOF'
import createMiddleware from 'next-intl/middleware';
import { routing } from './i18n/routing';

export default createMiddleware(routing);

export const config = {
  matcher: ['/((?!api|_next|.*\\..*).*)'],
};
TSEOF

  echo "  ✅ i18n/routing.ts"
  echo "  ✅ i18n/request.ts"
  echo "  ✅ i18n/navigation.ts"
  echo "  ✅ middleware.ts"

else
  # react-i18next config
  LOCALE_LIST=$(printf "'%s', " "${LOCALE_ARRAY[@]}" | sed 's/, $//')
  cat > "src/i18n.ts" << TSEOF
import i18n from 'i18next';
import { initReactI18next } from 'react-i18next';
import Backend from 'i18next-http-backend';
import LanguageDetector from 'i18next-browser-languagedetector';

i18n
  .use(Backend)
  .use(LanguageDetector)
  .use(initReactI18next)
  .init({
    fallbackLng: '$DEFAULT_LOCALE',
    supportedLngs: [$LOCALE_LIST],
    ns: ['common', 'auth', 'errors'],
    defaultNS: 'common',

    backend: {
      loadPath: '/locales/{{lng}}/{{ns}}.json',
    },

    detection: {
      order: ['querystring', 'cookie', 'localStorage', 'navigator'],
      caches: ['cookie', 'localStorage'],
    },

    interpolation: {
      escapeValue: false,
    },
  });

export default i18n;
TSEOF

  # i18next-parser config
  cat > "i18next-parser.config.js" << JSEOF
module.exports = {
  locales: [$LOCALE_LIST],
  output: 'public/locales/\$LOCALE/\$NAMESPACE.json',
  input: ['src/**/*.{ts,tsx,js,jsx}'],
  defaultNamespace: 'common',
  keySeparator: '.',
  namespaceSeparator: ':',
  createOldCatalogs: false,
  failOnWarnings: false,
  verbose: true,
};
JSEOF

  echo "  ✅ src/i18n.ts"
  echo "  ✅ i18next-parser.config.js"
fi

# --- Add scripts to package.json ---
echo ""
echo "📝 Adding scripts to package.json..."

if command -v node &> /dev/null; then
  if [ "$FRAMEWORK" = "nextjs" ]; then
    node -e "
      const pkg = require('./package.json');
      pkg.scripts = pkg.scripts || {};
      pkg.scripts['i18n:check'] = 'node -e \"const en = require(\\\"./messages/en.json\\\"); const locales = [${LOCALE_LIST}].filter(l => l !== \\\"en\\\"); locales.forEach(l => { const msgs = require(\\\"./messages/\\\" + l + \\\".json\\\"); const missing = []; const check = (obj, ref, path=\\\"\\\") => { for (const k in ref) { const p = path ? path+\\\".\\\"+k : k; if (typeof ref[k] === \\\"object\\\") check(obj?.[k]||{}, ref[k], p); else if (!(k in (obj||{}))) missing.push(p); }}; check(msgs, en); if (missing.length) { console.log(l + \\\": \\\" + missing.length + \\\" missing keys\\\"); missing.forEach(k => console.log(\\\"  - \\\" + k)); } else console.log(l + \\\": all keys present\\\"); });\"';
      require('fs').writeFileSync('./package.json', JSON.stringify(pkg, null, 2) + '\n');
    "
  else
    node -e "
      const pkg = require('./package.json');
      pkg.scripts = pkg.scripts || {};
      pkg.scripts['i18n:extract'] = 'i18next-parser --config i18next-parser.config.js';
      pkg.scripts['i18n:check'] = 'node -e \"const en = require(\\\"./public/locales/en/common.json\\\"); const locales = [${LOCALE_LIST}].filter(l => l !== \\\"en\\\"); locales.forEach(l => { const msgs = require(\\\"./public/locales/\\\" + l + \\\"/common.json\\\"); const missing = Object.keys(en).filter(k => !(k in msgs)); if (missing.length) console.log(l + \\\": \\\" + missing.length + \\\" missing\\\"); else console.log(l + \\\": OK\\\"); });\"';
      require('fs').writeFileSync('./package.json', JSON.stringify(pkg, null, 2) + '\n');
    "
  fi
  echo "  ✅ Added i18n scripts to package.json"
else
  echo "  ⚠️  Node.js not found — add scripts manually"
fi

# --- Done ---
echo ""
echo "═══════════════════════════════════════════════════"
echo "✅ i18n setup complete!"
echo "═══════════════════════════════════════════════════"
echo ""
echo "Next steps:"
if [ "$FRAMEWORK" = "nextjs" ]; then
  echo "  1. Update next.config.mjs to use next-intl plugin"
  echo "  2. Create app/[locale]/layout.tsx with NextIntlClientProvider"
  echo "  3. Translate messages/ files for each locale"
  echo "  4. Run: $PM run i18n:check"
else
  echo "  1. Import 'src/i18n.ts' in your app entry point"
  echo "  2. Wrap your app with <Suspense> for lazy-loaded translations"
  echo "  3. Use useTranslation() hook in components"
  echo "  4. Run: $PM run i18n:extract  (to scan for new keys)"
  echo "  5. Run: $PM run i18n:check    (to verify all locales)"
fi
echo ""
