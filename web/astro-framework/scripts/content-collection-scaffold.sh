#!/usr/bin/env bash
#
# content-collection-scaffold.sh — Generate content collection boilerplate
#
# Creates a content collection with schema definition, sample entries,
# and a listing page. Run from the root of an Astro project.
#
# Usage:
#   ./content-collection-scaffold.sh <collection-name> [options]
#
# Options:
#   --fields=<fields>     Comma-separated fields (default: title,description,pubDate,draft)
#                         Supported types: string, number, date, boolean, tags
#                         Format: name:type (e.g., title:string,price:number)
#   --count=<n>           Number of sample entries to generate (default: 3)
#   --format=md|mdx       Content format (default: md)
#   --no-page             Skip creating the listing page
#
# Examples:
#   ./content-collection-scaffold.sh blog
#   ./content-collection-scaffold.sh products --fields=name:string,price:number,inStock:boolean
#   ./content-collection-scaffold.sh docs --format=mdx --count=5
#

set -euo pipefail

# --- Defaults ---
COLLECTION_NAME=""
FIELDS="title:string,description:string,pubDate:date,draft:boolean"
SAMPLE_COUNT=3
FORMAT="md"
CREATE_PAGE=true

# --- Parse arguments ---
for arg in "$@"; do
  case "$arg" in
    --fields=*)  FIELDS="${arg#--fields=}" ;;
    --count=*)   SAMPLE_COUNT="${arg#--count=}" ;;
    --format=*)  FORMAT="${arg#--format=}" ;;
    --no-page)   CREATE_PAGE=false ;;
    --help|-h)
      head -22 "$0" | tail -20
      exit 0
      ;;
    -*)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
    *)
      COLLECTION_NAME="$arg"
      ;;
  esac
done

if [[ -z "$COLLECTION_NAME" ]]; then
  echo "Error: Collection name is required." >&2
  echo "Usage: $0 <collection-name> [options]" >&2
  exit 1
fi

# --- Validate we're in an Astro project ---
if [[ ! -f "astro.config.mjs" && ! -f "astro.config.ts" ]]; then
  echo "Error: Not in an Astro project root (no astro.config.mjs/ts found)." >&2
  exit 1
fi

CONTENT_DIR="src/content/$COLLECTION_NAME"
CONFIG_FILE="src/content.config.ts"

echo "📁 Scaffolding collection: $COLLECTION_NAME"
echo "   Fields: $FIELDS"
echo "   Sample entries: $SAMPLE_COUNT"
echo "   Format: $FORMAT"
echo ""

# --- Create content directory ---
mkdir -p "$CONTENT_DIR"

# --- Parse fields into arrays ---
IFS=',' read -ra FIELD_ARRAY <<< "$FIELDS"

# --- Generate Zod schema lines ---
generate_schema() {
  for field_def in "${FIELD_ARRAY[@]}"; do
    IFS=':' read -r name type <<< "$field_def"
    case "$type" in
      string)  echo "    $name: z.string()," ;;
      number)  echo "    $name: z.number()," ;;
      date)    echo "    $name: z.coerce.date()," ;;
      boolean) echo "    $name: z.boolean().default(false)," ;;
      tags)    echo "    $name: z.array(z.string()).default([])," ;;
      *)       echo "    $name: z.string(), // unknown type '$type', defaulting to string" ;;
    esac
  done
}

# --- Generate or update content config ---
if [[ -f "$CONFIG_FILE" ]]; then
  echo "⚠️  $CONFIG_FILE already exists."
  echo "   Add the following collection definition manually:"
  echo ""
  echo "const $COLLECTION_NAME = defineCollection({"
  echo "  loader: glob({ pattern: '**/*.$FORMAT', base: './$CONTENT_DIR' }),"
  echo "  schema: z.object({"
  generate_schema
  echo "  }),"
  echo "});"
  echo ""
  echo "// Add '$COLLECTION_NAME' to the collections export"
  echo ""
else
  echo "📝 Creating $CONFIG_FILE"
  {
    echo "import { defineCollection } from 'astro:content';"
    echo "import { glob } from 'astro/loaders';"
    echo "import { z } from 'astro/zod';"
    echo ""
    echo "const $COLLECTION_NAME = defineCollection({"
    echo "  loader: glob({ pattern: '**/*.$FORMAT', base: './$CONTENT_DIR' }),"
    echo "  schema: z.object({"
    generate_schema
    echo "  }),"
    echo "});"
    echo ""
    echo "export const collections = { $COLLECTION_NAME };"
  } > "$CONFIG_FILE"
fi

# --- Generate sample entries ---
echo "📝 Creating $SAMPLE_COUNT sample entries"

for i in $(seq 1 "$SAMPLE_COUNT"); do
  FILENAME="$CONTENT_DIR/sample-entry-$i.$FORMAT"

  {
    echo "---"
    for field_def in "${FIELD_ARRAY[@]}"; do
      IFS=':' read -r name type <<< "$field_def"
      case "$type" in
        string)  echo "$name: \"Sample ${name} $i\"" ;;
        number)  echo "$name: $((i * 10))" ;;
        date)    echo "$name: 2024-0$i-15" ;;
        boolean) echo "$name: false" ;;
        tags)    echo "$name: [\"tag-$i\", \"sample\"]" ;;
        *)       echo "$name: \"value-$i\"" ;;
      esac
    done
    echo "---"
    echo ""
    echo "# Sample Entry $i"
    echo ""
    echo "This is sample content for the **$COLLECTION_NAME** collection."
    echo ""
    echo "Replace this with your actual content."
  } > "$FILENAME"
  echo "   ✅ $FILENAME"
done

# --- Generate listing page ---
if [[ "$CREATE_PAGE" == true ]]; then
  PAGE_DIR="src/pages/$COLLECTION_NAME"
  mkdir -p "$PAGE_DIR"

  PAGE_FILE="$PAGE_DIR/index.astro"
  echo "📝 Creating listing page: $PAGE_FILE"

  # Determine the main display field (first string field, or 'title')
  DISPLAY_FIELD="id"
  for field_def in "${FIELD_ARRAY[@]}"; do
    IFS=':' read -r name type <<< "$field_def"
    if [[ "$type" == "string" ]]; then
      DISPLAY_FIELD="$name"
      break
    fi
  done

  cat > "$PAGE_FILE" << LISTING
---
import { getCollection } from 'astro:content';

const entries = await getCollection('$COLLECTION_NAME');
---
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>${COLLECTION_NAME^} Collection</title>
</head>
<body>
  <h1>${COLLECTION_NAME^}</h1>
  <ul>
    {entries.map((entry) => (
      <li>
        <a href={\`/$COLLECTION_NAME/\${entry.id}\`}>
          {entry.data.$DISPLAY_FIELD}
        </a>
      </li>
    ))}
  </ul>
</body>
</html>
LISTING

  # Create detail page
  DETAIL_FILE="$PAGE_DIR/[id].astro"
  cat > "$DETAIL_FILE" << 'DETAIL'
---
import { getCollection, getEntry } from 'astro:content';

export async function getStaticPaths() {
DETAIL

  cat >> "$DETAIL_FILE" << DETAIL
  const entries = await getCollection('$COLLECTION_NAME');
DETAIL

  cat >> "$DETAIL_FILE" << 'DETAIL'
  return entries.map((entry) => ({
    params: { id: entry.id },
  }));
}

const { id } = Astro.params;
DETAIL

  cat >> "$DETAIL_FILE" << DETAIL
const entry = await getEntry('$COLLECTION_NAME', id!);
DETAIL

  cat >> "$DETAIL_FILE" << 'DETAIL'
if (!entry) return Astro.redirect('/404');
const { Content } = await entry.render();
---
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>{entry.data.title ?? entry.id}</title>
</head>
<body>
  <article>
    <Content />
  </article>
  <a href="javascript:history.back()">← Back</a>
</body>
</html>
DETAIL

  echo "   ✅ $PAGE_FILE"
  echo "   ✅ $DETAIL_FILE"
fi

echo ""
echo "✅ Collection '$COLLECTION_NAME' scaffolded successfully!"
echo ""
echo "Next steps:"
echo "  1. Review/update the schema in $CONFIG_FILE"
echo "  2. Edit sample entries in $CONTENT_DIR/"
echo "  3. Run: npm run dev"
echo ""
