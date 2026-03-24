#!/usr/bin/env bash
# ============================================================================
# generate-pom.sh — Generate a Page Object Model class from a URL
#
# Usage:
#   ./generate-pom.sh <url> [--output <file>] [--class <ClassName>]
#
# Scrapes the given URL for interactive elements and generates a TypeScript
# Page Object Model class with locator properties and action methods.
#
# Requirements: npx (Node.js), Playwright installed in the project
# ============================================================================

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[pom-gen]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
error() { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") <url> [OPTIONS]

Generate a Page Object Model class by scraping a URL for interactive elements.

Arguments:
  <url>                 URL to scrape (e.g., http://localhost:3000/login)

Options:
  --output <file>       Output file path (default: auto-generated from URL path)
  --class <name>        Class name (default: auto-generated from URL path)
  --dir <path>          Output directory (default: ./tests/pages)
  -h, --help            Show this help message

Examples:
  $(basename "$0") http://localhost:3000/login
  $(basename "$0") http://localhost:3000/settings --class SettingsPage
  $(basename "$0") https://example.com/dashboard --output tests/pages/dashboard-page.ts
EOF
  exit 0
}

# Defaults
TARGET_URL=""
OUTPUT_FILE=""
CLASS_NAME=""
OUTPUT_DIR="./tests/pages"

# Parse arguments
[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)  OUTPUT_FILE="$2"; shift 2 ;;
    --class)   CLASS_NAME="$2"; shift 2 ;;
    --dir)     OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*)        error "Unknown option: $1. Use --help for usage." ;;
    *)
      if [[ -z "$TARGET_URL" ]]; then
        TARGET_URL="$1"; shift
      else
        error "Unexpected argument: $1"
      fi
      ;;
  esac
done

[[ -z "$TARGET_URL" ]] && error "URL is required. Use --help for usage."

# Derive names from URL path
URL_PATH=$(echo "$TARGET_URL" | sed -E 's|https?://[^/]+||; s|/$||; s|^/||; s|/|-|g')
[[ -z "$URL_PATH" ]] && URL_PATH="home"

if [[ -z "$CLASS_NAME" ]]; then
  # Convert path to PascalCase and append "Page"
  CLASS_NAME=$(echo "$URL_PATH" | sed -E 's/(^|-)([a-z])/\U\2/g')
  CLASS_NAME="${CLASS_NAME}Page"
fi

if [[ -z "$OUTPUT_FILE" ]]; then
  OUTPUT_FILE="${OUTPUT_DIR}/${URL_PATH}-page.ts"
fi

# Ensure output directory exists
mkdir -p "$(dirname "$OUTPUT_FILE")"

log "Scraping $TARGET_URL for interactive elements..."

# Create temporary scraper script
SCRAPER_SCRIPT=$(mktemp /tmp/pom-scraper-XXXXXX.mjs)
trap 'rm -f "$SCRAPER_SCRIPT"' EXIT

cat > "$SCRAPER_SCRIPT" << 'SCRAPEREOF'
import { chromium } from '@playwright/test';

const url = process.argv[2];
if (!url) { console.error('URL required'); process.exit(1); }

(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();

  try {
    await page.goto(url, { waitUntil: 'networkidle', timeout: 30000 });
  } catch {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
  }

  const elements = await page.evaluate(() => {
    const results = [];
    const seen = new Set();

    function addElement(type, role, name, selector, tag) {
      const key = `${type}:${name || selector}`;
      if (seen.has(key)) return;
      seen.add(key);
      results.push({ type, role, name, selector, tag });
    }

    // Buttons
    document.querySelectorAll('button, [role="button"], input[type="submit"], input[type="button"]').forEach(el => {
      const name = el.textContent?.trim() || el.getAttribute('aria-label') || el.getAttribute('value') || '';
      if (name) addElement('button', 'button', name, '', el.tagName.toLowerCase());
    });

    // Inputs
    document.querySelectorAll('input:not([type="hidden"]):not([type="submit"]):not([type="button"]), textarea').forEach(el => {
      const label = el.getAttribute('aria-label')
        || document.querySelector(`label[for="${el.id}"]`)?.textContent?.trim()
        || el.getAttribute('placeholder')
        || el.getAttribute('name')
        || '';
      const inputType = el.getAttribute('type') || 'text';
      if (label) addElement('input', inputType, label, '', el.tagName.toLowerCase());
    });

    // Select dropdowns
    document.querySelectorAll('select').forEach(el => {
      const label = el.getAttribute('aria-label')
        || document.querySelector(`label[for="${el.id}"]`)?.textContent?.trim()
        || el.getAttribute('name')
        || '';
      if (label) addElement('select', 'combobox', label, '', 'select');
    });

    // Links (navigation)
    document.querySelectorAll('a[href]').forEach(el => {
      const name = el.textContent?.trim() || el.getAttribute('aria-label') || '';
      if (name && name.length < 80) addElement('link', 'link', name, el.getAttribute('href'), 'a');
    });

    // Checkboxes and radios
    document.querySelectorAll('input[type="checkbox"], input[type="radio"]').forEach(el => {
      const label = el.getAttribute('aria-label')
        || document.querySelector(`label[for="${el.id}"]`)?.textContent?.trim()
        || '';
      if (label) addElement(el.type, el.type, label, '', 'input');
    });

    // Headings
    document.querySelectorAll('h1, h2, h3').forEach(el => {
      const text = el.textContent?.trim();
      const level = parseInt(el.tagName[1]);
      if (text) addElement('heading', `heading-${level}`, text, '', el.tagName.toLowerCase());
    });

    return results;
  });

  console.log(JSON.stringify(elements));
  await browser.close();
})();
SCRAPEREOF

# Run scraper
ELEMENTS_JSON=$(npx --no-install node "$SCRAPER_SCRIPT" "$TARGET_URL" 2>/dev/null) || {
  warn "Browser scraping failed. Generating skeleton POM class."
  ELEMENTS_JSON="[]"
}

# Generate TypeScript POM class
log "Generating Page Object Model class: $CLASS_NAME"

GENERATOR_SCRIPT=$(mktemp /tmp/pom-generator-XXXXXX.mjs)
trap 'rm -f "$SCRAPER_SCRIPT" "$GENERATOR_SCRIPT"' EXIT

cat > "$GENERATOR_SCRIPT" << 'GENEOF'
const elements = JSON.parse(process.argv[2]);
const className = process.argv[3];
const urlPath = process.argv[4];

function toCamelCase(str) {
  return str
    .replace(/[^a-zA-Z0-9\s]/g, '')
    .trim()
    .split(/\s+/)
    .map((w, i) => i === 0 ? w.toLowerCase() : w[0].toUpperCase() + w.slice(1).toLowerCase())
    .join('');
}

const lines = [];
lines.push(`import { type Page, type Locator, expect } from '@playwright/test';`);
lines.push(``);
lines.push(`export class ${className} {`);
lines.push(`  readonly url = '/${urlPath}';`);
lines.push(``);

// Collect locator declarations
const locators = [];
const methods = [];
const seenNames = new Set();

for (const el of elements) {
  if (!el.name) continue;
  let varName = toCamelCase(el.name);
  if (!varName || seenNames.has(varName)) continue;
  seenNames.add(varName);

  switch (el.type) {
    case 'button':
      varName += 'Button';
      locators.push({ name: varName, init: `page.getByRole('button', { name: '${el.name.replace(/'/g, "\\'")}' })` });
      methods.push(`  async click${varName[0].toUpperCase() + varName.slice(1)}() {\n    await this.${varName}.click();\n  }`);
      break;
    case 'input':
      varName += 'Input';
      locators.push({ name: varName, init: `page.getByLabel('${el.name.replace(/'/g, "\\'")}')` });
      methods.push(`  async fill${varName[0].toUpperCase() + varName.slice(1)}(value: string) {\n    await this.${varName}.fill(value);\n  }`);
      break;
    case 'select':
      varName += 'Select';
      locators.push({ name: varName, init: `page.getByLabel('${el.name.replace(/'/g, "\\'")}')` });
      methods.push(`  async select${varName[0].toUpperCase() + varName.slice(1)}(value: string) {\n    await this.${varName}.selectOption(value);\n  }`);
      break;
    case 'link':
      varName += 'Link';
      locators.push({ name: varName, init: `page.getByRole('link', { name: '${el.name.replace(/'/g, "\\'")}' })` });
      break;
    case 'checkbox':
      varName += 'Checkbox';
      locators.push({ name: varName, init: `page.getByLabel('${el.name.replace(/'/g, "\\'")}')` });
      methods.push(`  async toggle${varName[0].toUpperCase() + varName.slice(1)}() {\n    await this.${varName}.check();\n  }`);
      break;
    case 'heading':
      const level = el.role.split('-')[1];
      varName += 'Heading';
      locators.push({ name: varName, init: `page.getByRole('heading', { name: '${el.name.replace(/'/g, "\\'")}', level: ${level} })` });
      break;
  }
}

// Write locator properties
for (const loc of locators) {
  lines.push(`  readonly ${loc.name}: Locator;`);
}

// Constructor
lines.push(``);
lines.push(`  constructor(private readonly page: Page) {`);
for (const loc of locators) {
  lines.push(`    this.${loc.name} = ${loc.init};`);
}
lines.push(`  }`);

// Navigation method
lines.push(``);
lines.push(`  async goto() {`);
lines.push(`    await this.page.goto(this.url);`);
lines.push(`  }`);

// Action methods
for (const method of methods) {
  lines.push(``);
  lines.push(method);
}

lines.push(`}`);
lines.push(``);

process.stdout.write(lines.join('\n'));
GENEOF

node "$GENERATOR_SCRIPT" "$ELEMENTS_JSON" "$CLASS_NAME" "$URL_PATH" > "$OUTPUT_FILE"

ELEMENT_COUNT=$(echo "$ELEMENTS_JSON" | node -e "const d=require('fs').readFileSync(0,'utf8'); console.log(JSON.parse(d).length)" 2>/dev/null || echo "0")
LINE_COUNT=$(wc -l < "$OUTPUT_FILE")

log "Generated $OUTPUT_FILE"
log "  Class: $CLASS_NAME"
log "  Elements found: $ELEMENT_COUNT"
log "  Lines: $LINE_COUNT"
echo ""
echo "  Next steps:"
echo "    1. Review and adjust locators in $OUTPUT_FILE"
echo "    2. Add custom action methods for page workflows"
echo "    3. Import and use in your tests:"
echo ""
echo "      import { ${CLASS_NAME} } from './pages/$(basename "$OUTPUT_FILE" .ts)';"
echo ""
echo "      test('example', async ({ page }) => {"
echo "        const myPage = new ${CLASS_NAME}(page);"
echo "        await myPage.goto();"
echo "      });"
