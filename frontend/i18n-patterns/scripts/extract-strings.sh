#!/usr/bin/env bash
# =============================================================================
# extract-strings.sh — Extract translatable strings from source code
#
# Usage:
#   ./extract-strings.sh [--src <dir>] [--out <file>] [--format json|pot]
#
# Examples:
#   ./extract-strings.sh                              # scan src/, output keys.json
#   ./extract-strings.sh --src app/ --out strings.json
#   ./extract-strings.sh --format pot --out messages.pot
#
# What it does:
#   1. Scans source files for t(), useTranslation, <FormattedMessage>, etc.
#   2. Extracts translation keys and default values
#   3. Generates JSON or POT output file
#   4. Reports untranslated keys by comparing with existing locale files
#   5. Detects duplicate keys across namespaces
# =============================================================================
set -euo pipefail

# --- Defaults ---
SRC_DIR="src"
OUT_FILE=""
FORMAT="json"
LOCALE_DIR=""
VERBOSE=false

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --src)     SRC_DIR="$2";    shift 2 ;;
    --out)     OUT_FILE="$2";   shift 2 ;;
    --format)  FORMAT="$2";     shift 2 ;;
    --locales) LOCALE_DIR="$2"; shift 2 ;;
    --verbose) VERBOSE=true;    shift   ;;
    --help|-h) head -16 "$0" | tail -14; exit 0 ;;
    *)         echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Auto-detect locale directory
if [ -z "$LOCALE_DIR" ]; then
  if [ -d "messages" ]; then
    LOCALE_DIR="messages"
  elif [ -d "public/locales" ]; then
    LOCALE_DIR="public/locales"
  fi
fi

# Default output file
if [ -z "$OUT_FILE" ]; then
  OUT_FILE="extracted-keys.${FORMAT}"
fi

echo "🔍 Scanning: $SRC_DIR"
echo "📄 Output:   $OUT_FILE ($FORMAT)"
echo ""

# --- Ensure source directory exists ---
if [ ! -d "$SRC_DIR" ]; then
  echo "❌ Source directory '$SRC_DIR' not found."
  exit 1
fi

# --- Extract keys using Node.js ---
if ! command -v node &> /dev/null; then
  echo "❌ Node.js is required. Install it and try again."
  exit 1
fi

node << 'NODEOF'
const fs = require('fs');
const path = require('path');

const srcDir = process.env.SRC_DIR || 'src';
const outFile = process.env.OUT_FILE || 'extracted-keys.json';
const format = process.env.FORMAT || 'json';
const localeDir = process.env.LOCALE_DIR || '';
const verbose = process.env.VERBOSE === 'true';

// Patterns to match translation function calls
const patterns = [
  // t('key'), t("key"), t(`key`)
  /\bt\(\s*['"`]([^'"`\n]+?)['"`]/g,
  // i18n.t('key')
  /i18n\.t\(\s*['"`]([^'"`\n]+?)['"`]/g,
  // intl.formatMessage({ id: 'key' })
  /formatMessage\(\s*\{\s*id:\s*['"`]([^'"`\n]+?)['"`]/g,
  // <FormattedMessage id="key" />
  /<FormattedMessage[^>]*\bid=['"`]([^'"`\n]+?)['"`]/g,
  // useTranslations('namespace')
  /useTranslations\(\s*['"`]([^'"`\n]+?)['"`]/g,
  // <Trans i18nKey="key" />
  /<Trans[^>]*\bi18nKey=['"`]([^'"`\n]+?)['"`]/g,
];

// File extensions to scan
const extensions = new Set(['.ts', '.tsx', '.js', '.jsx']);

// Recursively find source files
function findFiles(dir) {
  const results = [];
  try {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const entry of entries) {
      const fullPath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (!['node_modules', '.next', 'dist', 'build', '.git'].includes(entry.name)) {
          results.push(...findFiles(fullPath));
        }
      } else if (extensions.has(path.extname(entry.name))) {
        results.push(fullPath);
      }
    }
  } catch (e) { /* skip unreadable dirs */ }
  return results;
}

// Extract keys from a file
function extractKeys(filePath, content) {
  const keys = [];
  for (const pattern of patterns) {
    // Reset lastIndex for each file
    const regex = new RegExp(pattern.source, pattern.flags);
    let match;
    while ((match = regex.exec(content)) !== null) {
      const key = match[1];
      const line = content.substring(0, match.index).split('\n').length;
      keys.push({ key, file: filePath, line });
    }
  }
  return keys;
}

// --- Main extraction ---
console.log('Scanning files...');
const files = findFiles(srcDir);
console.log(`  Found ${files.length} source files`);

const allKeys = [];
const keyMap = new Map(); // key → locations

for (const file of files) {
  const content = fs.readFileSync(file, 'utf-8');
  const keys = extractKeys(file, content);
  for (const entry of keys) {
    allKeys.push(entry);
    if (!keyMap.has(entry.key)) keyMap.set(entry.key, []);
    keyMap.get(entry.key).push({ file: entry.file, line: entry.line });
  }
}

const uniqueKeys = [...keyMap.keys()].sort();
console.log(`  Extracted ${uniqueKeys.length} unique keys (${allKeys.length} total references)`);

// --- Generate output ---
if (format === 'pot') {
  // Generate POT (Portable Object Template) file
  const lines = [
    '# Translation strings extracted by extract-strings.sh',
    `# Generated: ${new Date().toISOString()}`,
    `# Source: ${srcDir}`,
    '',
    'msgid ""',
    'msgstr ""',
    `"Content-Type: text/plain; charset=UTF-8\\n"`,
    `"Content-Transfer-Encoding: 8bit\\n"`,
    '',
  ];

  for (const key of uniqueKeys) {
    const locations = keyMap.get(key);
    for (const loc of locations) {
      lines.push(`#: ${loc.file}:${loc.line}`);
    }
    lines.push(`msgid "${key.replace(/"/g, '\\"')}"`);
    lines.push('msgstr ""');
    lines.push('');
  }

  fs.writeFileSync(outFile, lines.join('\n'));
} else {
  // Generate JSON file
  const output = {};
  for (const key of uniqueKeys) {
    // Build nested structure from dot-notation keys
    const parts = key.split('.');
    let current = output;
    for (let i = 0; i < parts.length - 1; i++) {
      if (!(parts[i] in current)) current[parts[i]] = {};
      current = current[parts[i]];
    }
    current[parts[parts.length - 1]] = key; // placeholder value = key itself
  }
  fs.writeFileSync(outFile, JSON.stringify(output, null, 2) + '\n');
}

console.log(`\n✅ Written to ${outFile}`);

// --- Compare with existing translations ---
if (localeDir && fs.existsSync(localeDir)) {
  console.log(`\n📊 Comparing with translations in ${localeDir}:`);

  // Flatten a nested object to dot-notation keys
  function flattenKeys(obj, prefix = '') {
    const keys = [];
    for (const [k, v] of Object.entries(obj)) {
      const fullKey = prefix ? `${prefix}.${k}` : k;
      if (typeof v === 'object' && v !== null && !Array.isArray(v)) {
        keys.push(...flattenKeys(v, fullKey));
      } else {
        keys.push(fullKey);
      }
    }
    return keys;
  }

  const entries = fs.readdirSync(localeDir, { withFileTypes: true });
  for (const entry of entries) {
    let localeKeys = [];
    const localeName = entry.name.replace('.json', '');

    if (entry.isDirectory()) {
      // react-i18next structure: localeDir/en/common.json
      const nsFiles = fs.readdirSync(path.join(localeDir, entry.name))
        .filter(f => f.endsWith('.json'));
      for (const nsFile of nsFiles) {
        const ns = nsFile.replace('.json', '');
        const data = JSON.parse(fs.readFileSync(path.join(localeDir, entry.name, nsFile), 'utf-8'));
        localeKeys.push(...flattenKeys(data).map(k => `${ns}.${k}`));
      }
    } else if (entry.name.endsWith('.json')) {
      // next-intl structure: localeDir/en.json
      const data = JSON.parse(fs.readFileSync(path.join(localeDir, entry.name), 'utf-8'));
      localeKeys = flattenKeys(data);
    } else {
      continue;
    }

    const localeKeySet = new Set(localeKeys);
    const missing = uniqueKeys.filter(k => !localeKeySet.has(k));
    const unused = localeKeys.filter(k => !keyMap.has(k));

    if (missing.length === 0 && unused.length === 0) {
      console.log(`  ✅ ${localeName}: all keys present, no unused keys`);
    } else {
      if (missing.length > 0) {
        console.log(`  ⚠️  ${localeName}: ${missing.length} missing key(s)`);
        if (verbose) missing.forEach(k => console.log(`      - ${k}`));
      }
      if (unused.length > 0) {
        console.log(`  🗑️  ${localeName}: ${unused.length} unused key(s)`);
        if (verbose) unused.forEach(k => console.log(`      - ${k}`));
      }
    }
  }
}

// --- Detect duplicates (keys used in multiple namespaces) ---
const duplicates = [...keyMap.entries()].filter(([, locs]) => {
  const files = new Set(locs.map(l => l.file));
  return files.size > 3; // key used in more than 3 files
});

if (duplicates.length > 0) {
  console.log(`\n💡 Keys used in 4+ files (consider moving to shared namespace):`);
  for (const [key, locs] of duplicates.slice(0, 10)) {
    console.log(`  ${key} — ${new Set(locs.map(l => l.file)).size} files`);
  }
}

console.log('\nDone.');
NODEOF
