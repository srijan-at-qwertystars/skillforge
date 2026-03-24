#!/usr/bin/env bash
# =============================================================================
# pseudo-localize.sh — Generate pseudo-localized translation files
#
# Usage:
#   ./pseudo-localize.sh [--input <file|dir>] [--output <file|dir>] [--expand <percent>]
#
# Examples:
#   ./pseudo-localize.sh --input messages/en.json --output messages/pseudo.json
#   ./pseudo-localize.sh --input public/locales/en/ --output public/locales/pseudo/
#   ./pseudo-localize.sh --input messages/en.json --expand 40
#
# What it does:
#   1. Reads source translation file(s) (default: English)
#   2. Applies diacritics to ASCII characters (a→á, e→é, etc.)
#   3. Expands strings by specified percentage (default 30%) with padding
#   4. Wraps strings in brackets [] to spot untranslated/truncated text
#   5. Preserves ICU placeholders, HTML tags, and interpolation variables
#   6. Outputs pseudo-localized file(s) for visual testing
# =============================================================================
set -euo pipefail

# --- Defaults ---
INPUT=""
OUTPUT=""
EXPAND=30

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --input|-i)  INPUT="$2";  shift 2 ;;
    --output|-o) OUTPUT="$2"; shift 2 ;;
    --expand|-e) EXPAND="$2"; shift 2 ;;
    --help|-h)   head -18 "$0" | tail -16; exit 0 ;;
    *)           echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Auto-detect input ---
if [ -z "$INPUT" ]; then
  if [ -f "messages/en.json" ]; then
    INPUT="messages/en.json"
  elif [ -d "public/locales/en" ]; then
    INPUT="public/locales/en"
  else
    echo "❌ No input specified and couldn't auto-detect."
    echo "   Use --input <file|dir> to specify source translations."
    exit 1
  fi
fi

# --- Auto-detect output ---
if [ -z "$OUTPUT" ]; then
  if [ -f "$INPUT" ]; then
    OUTPUT="${INPUT%/*}/pseudo.json"
  elif [ -d "$INPUT" ]; then
    OUTPUT="${INPUT%/*}/pseudo"
  fi
fi

echo "🔤 Input:    $INPUT"
echo "📄 Output:   $OUTPUT"
echo "📏 Expand:   ${EXPAND}%"
echo ""

# --- Ensure Node.js is available ---
if ! command -v node &> /dev/null; then
  echo "❌ Node.js is required. Install it and try again."
  exit 1
fi

# --- Process with Node.js ---
EXPAND_PCT="$EXPAND" INPUT_PATH="$INPUT" OUTPUT_PATH="$OUTPUT" node << 'NODEOF'
const fs = require('fs');
const path = require('path');

const inputPath = process.env.INPUT_PATH;
const outputPath = process.env.OUTPUT_PATH;
const expandPct = parseInt(process.env.EXPAND_PCT || '30', 10) / 100;

// Character map: ASCII → accented equivalents
const CHAR_MAP = {
  'a': 'á', 'b': 'ƀ', 'c': 'ç', 'd': 'ð', 'e': 'é', 'f': 'ƒ',
  'g': 'ĝ', 'h': 'ĥ', 'i': 'í', 'j': 'ĵ', 'k': 'ķ', 'l': 'ĺ',
  'm': 'ɱ', 'n': 'ñ', 'o': 'ó', 'p': 'þ', 'q': 'ǫ', 'r': 'ŕ',
  's': 'š', 't': 'ţ', 'u': 'ú', 'v': 'ṽ', 'w': 'ŵ', 'x': 'ẋ',
  'y': 'ý', 'z': 'ž',
  'A': 'Á', 'B': 'Ɓ', 'C': 'Ç', 'D': 'Ð', 'E': 'É', 'F': 'Ƒ',
  'G': 'Ĝ', 'H': 'Ĥ', 'I': 'Í', 'J': 'Ĵ', 'K': 'Ķ', 'L': 'Ĺ',
  'M': 'Ṁ', 'N': 'Ñ', 'O': 'Ó', 'P': 'Þ', 'Q': 'Ǫ', 'R': 'Ŕ',
  'S': 'Š', 'T': 'Ţ', 'U': 'Ú', 'V': 'Ṽ', 'W': 'Ŵ', 'X': 'Ẋ',
  'Y': 'Ý', 'Z': 'Ž',
};

// Padding characters for string expansion
const PADDING_CHARS = '~·¤¥¢£';

/**
 * Pseudo-localize a single string value.
 * Preserves:
 *  - ICU placeholders: {name}, {count, plural, ...}
 *  - HTML tags: <bold>, </link>, <br />
 *  - Interpolation: {{variable}}, {variable}
 *  - Escaped braces
 */
function pseudoLocalize(str) {
  if (typeof str !== 'string') return str;
  if (str.trim() === '') return str;

  let result = '';
  let i = 0;
  let visibleCharCount = 0;

  while (i < str.length) {
    // Skip HTML tags: <tag>, </tag>, <tag />
    if (str[i] === '<') {
      const tagEnd = str.indexOf('>', i);
      if (tagEnd !== -1) {
        result += str.substring(i, tagEnd + 1);
        i = tagEnd + 1;
        continue;
      }
    }

    // Skip ICU/interpolation placeholders: {name}, {{var}}, {count, plural, ...}
    if (str[i] === '{') {
      let depth = 0;
      let j = i;
      while (j < str.length) {
        if (str[j] === '{') depth++;
        else if (str[j] === '}') {
          depth--;
          if (depth === 0) break;
        }
        j++;
      }
      result += str.substring(i, j + 1);
      i = j + 1;
      continue;
    }

    // Apply diacritics to ASCII letters
    const char = str[i];
    if (CHAR_MAP[char]) {
      result += CHAR_MAP[char];
      visibleCharCount++;
    } else {
      result += char;
      if (char.trim() !== '' && char !== '{' && char !== '}') {
        visibleCharCount++;
      }
    }
    i++;
  }

  // Add expansion padding
  const paddingLength = Math.ceil(visibleCharCount * expandPct);
  let padding = '';
  for (let p = 0; p < paddingLength; p++) {
    padding += PADDING_CHARS[p % PADDING_CHARS.length];
  }

  // Wrap in brackets for visual detection
  return `[${result} ${padding}]`;
}

/**
 * Recursively process a translation object.
 */
function processObject(obj) {
  const result = {};
  for (const [key, value] of Object.entries(obj)) {
    if (typeof value === 'string') {
      result[key] = pseudoLocalize(value);
    } else if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      result[key] = processObject(value);
    } else {
      result[key] = value; // preserve arrays, numbers, booleans
    }
  }
  return result;
}

/**
 * Process a single JSON file.
 */
function processFile(inputFile, outputFile) {
  const content = JSON.parse(fs.readFileSync(inputFile, 'utf-8'));
  const pseudo = processObject(content);
  const dir = path.dirname(outputFile);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(outputFile, JSON.stringify(pseudo, null, 2) + '\n');

  const keyCount = JSON.stringify(content).split('"').length; // rough count
  console.log(`  ✅ ${path.basename(inputFile)} → ${path.basename(outputFile)}`);
}

// --- Main ---
const inputStat = fs.statSync(inputPath);

if (inputStat.isFile()) {
  // Single file mode
  processFile(inputPath, outputPath);
} else if (inputStat.isDirectory()) {
  // Directory mode — process all JSON files
  if (!fs.existsSync(outputPath)) fs.mkdirSync(outputPath, { recursive: true });

  const files = fs.readdirSync(inputPath).filter(f => f.endsWith('.json'));
  for (const file of files) {
    processFile(
      path.join(inputPath, file),
      path.join(outputPath, file)
    );
  }
}

// --- Show sample output ---
console.log('\n📋 Sample pseudo-localized strings:');
const sampleInput = inputStat.isFile() ? inputPath : path.join(inputPath, fs.readdirSync(inputPath).find(f => f.endsWith('.json')) || '');
if (fs.existsSync(sampleInput)) {
  const sample = JSON.parse(fs.readFileSync(sampleInput, 'utf-8'));
  let count = 0;
  function showSamples(obj, prefix = '') {
    for (const [key, value] of Object.entries(obj)) {
      if (count >= 5) return;
      const fullKey = prefix ? `${prefix}.${key}` : key;
      if (typeof value === 'string') {
        console.log(`  "${fullKey}": "${value}"`);
        console.log(`  → ${pseudoLocalize(value)}`);
        console.log('');
        count++;
      } else if (typeof value === 'object') {
        showSamples(value, fullKey);
      }
    }
  }
  showSamples(sample);
}

console.log('Done. Use the pseudo locale to test:');
console.log('  - Text truncation (expanded strings)');
console.log('  - Character encoding (diacritics)');
console.log('  - Untranslated strings (missing brackets)');
console.log('  - Layout flexibility');
NODEOF
