# Meilisearch Troubleshooting Reference

Common issues, diagnostics, and solutions for Meilisearch deployments.

---

## Table of Contents

1. [Indexing Stuck or Slow](#1-indexing-stuck-or-slow)
2. [Large Dataset Imports](#2-large-dataset-imports)
3. [Memory Usage](#3-memory-usage)
4. [Search Relevancy Not Matching Expectations](#4-search-relevancy-not-matching-expectations)
5. [Ranking Rules Misconfiguration](#5-ranking-rules-misconfiguration)
6. [Filterable Attributes Not Set](#6-filterable-attributes-not-set)
7. [API Key Permission Errors](#7-api-key-permission-errors)
8. [Docker Volume Data Persistence](#8-docker-volume-data-persistence)
9. [Snapshot and Dump Restore Failures](#9-snapshot-and-dump-restore-failures)
10. [Version Upgrade Migrations](#10-version-upgrade-migrations)
11. [Network and Connection Issues](#11-network-and-connection-issues)
12. [Payload Too Large](#12-payload-too-large)

---

## 1. Indexing Stuck or Slow

### Symptoms

- Documents added via `/documents` never become searchable.
- `GET /tasks` shows a long queue of `enqueued` tasks that do not transition to `processing`.
- Tasks complete but take far longer than expected (minutes or hours for moderate datasets).
- CPU usage stays pegged at 100 % for extended periods during indexing.

### Cause

- The task queue is serial — each task must finish before the next begins. A single slow or failed task blocks the entire queue.
- Insufficiently tuned indexing memory or thread limits starve the indexer.
- Sending documents in very large or very small batches creates overhead.
- Changing settings (e.g., `searchableAttributes`, `filterableAttributes`) after a bulk import forces a full reindex of every document.

### Diagnosis

Check the task queue status:

```bash
# List recent tasks to see current state
curl -s 'http://localhost:7700/tasks?limit=10' \
  -H 'Authorization: Bearer YOUR_API_KEY' | jq '.results[] | {uid, status, type, duration}'
```

Look for tasks stuck in `enqueued` or `processing` for abnormally long durations.

Identify failed tasks that may be blocking progress:

```bash
# Filter for failed tasks
curl -s 'http://localhost:7700/tasks?statuses=failed&limit=5' \
  -H 'Authorization: Bearer YOUR_API_KEY' | jq '.results[] | {uid, type, error}'
```

Check index stats to see document count and whether indexing is progressing:

```bash
curl -s 'http://localhost:7700/indexes/YOUR_INDEX/stats' \
  -H 'Authorization: Bearer YOUR_API_KEY' | jq .
```

### Solution

**1. Tune indexing resources.**

Set environment variables before starting Meilisearch:

```bash
# Allow the indexer to use up to 4 GiB of RAM (default is 2/3 of total RAM)
export MEILI_MAX_INDEXING_MEMORY=4Gib

# Limit indexing threads to leave cores free for search (default: half of available cores)
export MEILI_MAX_INDEXING_THREADS=4
```

**2. Batch documents properly.**

Aim for 10,000–50,000 documents per batch. Tiny batches (< 1,000) create excessive task overhead. Giant batches (> 100,000) spike memory usage.

```bash
# Good: 20k documents per request
curl -X POST 'http://localhost:7700/indexes/products/documents' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary @batch_20k.json
```

**3. Configure settings before bulk import.**

Apply `searchableAttributes`, `filterableAttributes`, `sortableAttributes`, and ranking rules first, then import documents. This avoids a costly reindex.

```bash
# Set all settings FIRST
curl -X PATCH 'http://localhost:7700/indexes/products/settings' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "searchableAttributes": ["name", "description", "brand"],
    "filterableAttributes": ["category", "price", "inStock"],
    "sortableAttributes": ["price", "releaseDate"]
  }'

# Wait for the settings task to complete, THEN import documents
```

**4. Cancel stuck tasks.**

```bash
# Cancel all enqueued tasks for a specific index
curl -X POST 'http://localhost:7700/tasks/cancel?statuses=enqueued&indexUids=products' \
  -H 'Authorization: Bearer YOUR_API_KEY'
```

---

## 2. Large Dataset Imports

### Symptoms

- Import requests time out or fail with connection reset errors.
- Meilisearch process crashes or gets OOM-killed during import.
- Disk usage grows unexpectedly large during ingestion.

### Cause

- Sending millions of documents in a single request exceeds memory limits and payload size.
- JSON arrays require the entire payload to be parsed into memory before indexing begins.
- Documents contain large fields (long text, base64 blobs) that inflate memory usage.

### Diagnosis

Check how large the payload is:

```bash
# Check file size of your dataset
ls -lh dataset.json
wc -l dataset.ndjson
```

Monitor Meilisearch memory usage during import:

```bash
# Watch RSS memory of the Meilisearch process
watch -n 2 'ps -o pid,rss,vsz,comm -p $(pgrep meilisearch)'
```

### Solution

**1. Use NDJSON format for streaming.**

NDJSON (newline-delimited JSON) lets Meilisearch stream-parse documents without loading the full payload into memory.

```bash
curl -X POST 'http://localhost:7700/indexes/products/documents' \
  -H 'Content-Type: application/x-ndjson' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary @products.ndjson
```

Convert JSON array to NDJSON:

```bash
# Using jq to convert a JSON array to NDJSON
jq -c '.[]' products.json > products.ndjson
```

**2. Chunk large files.**

Split datasets into manageable pieces:

```bash
# Split NDJSON file into 20,000-line chunks
split -l 20000 products.ndjson chunk_
for file in chunk_*; do
  curl -X POST 'http://localhost:7700/indexes/products/documents' \
    -H 'Content-Type: application/x-ndjson' \
    -H 'Authorization: Bearer YOUR_API_KEY' \
    --data-binary @"$file"
  echo "Uploaded $file"
done
```

**3. Monitor task progress.**

After submitting chunks, poll task status:

```bash
# Get the taskUid from the response, then poll
TASK_UID=42
while true; do
  STATUS=$(curl -s "http://localhost:7700/tasks/$TASK_UID" \
    -H 'Authorization: Bearer YOUR_API_KEY' | jq -r '.status')
  echo "Task $TASK_UID: $STATUS"
  [ "$STATUS" = "succeeded" ] || [ "$STATUS" = "failed" ] && break
  sleep 5
done
```

**4. Optimize document structure.**

Remove fields that are not needed for search, filtering, or display before indexing:

```bash
# Strip unnecessary fields with jq before import
jq -c '{id, name, description, price, category}' products_full.ndjson > products_lean.ndjson
```

---

## 3. Memory Usage

### Symptoms

- Meilisearch process consumes far more RAM than expected.
- OOM killer terminates the process under load.
- System swap usage spikes, degrading search performance.
- Other services on the same host become unresponsive.

### Cause

- Meilisearch maps index data structures into memory. Each index contributes to total RSS.
- Having many `searchableAttributes` or `filterableAttributes` multiplies internal data structures.
- The indexer allocates additional temporary memory on top of the steady-state index size.

### Diagnosis

Check current memory usage per index:

```bash
curl -s 'http://localhost:7700/stats' \
  -H 'Authorization: Bearer YOUR_API_KEY' | jq '.indexes | to_entries[] | {index: .key, sizeBytes: .value.databaseSize, docs: .value.numberOfDocuments}'
```

Compare against system memory:

```bash
free -h
```

### Solution

**1. Size the server appropriately.**

A rough guideline: provision 2–3× the raw dataset size in RAM. A 2 GiB dataset should run on a machine with at least 4–6 GiB of RAM.

**2. Control indexing memory separately from total RAM.**

```bash
# Total system RAM: 8 GiB
# Reserve ~2 GiB for the OS and other processes
# Cap indexing at 4 GiB, leaving room for serving queries
export MEILI_MAX_INDEXING_MEMORY=4Gib
```

`MEILI_MAX_INDEXING_MEMORY` limits only the indexer's scratch space. The index itself still maps into memory for serving search queries. Do not set this value higher than about 60 % of total RAM.

**3. Reduce the number of indexed attributes.**

Only make attributes searchable or filterable if they are actually used:

```bash
curl -X PATCH 'http://localhost:7700/indexes/products/settings' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "searchableAttributes": ["name", "description"],
    "filterableAttributes": ["category", "price"]
  }'
```

Removing an attribute from `searchableAttributes` or `filterableAttributes` triggers a reindex but reduces the steady-state memory footprint.

**4. Monitor over time.**

Use the `/stats` endpoint in a cron job or monitoring system to track growth:

```bash
# Quick check — total database size across all indexes
curl -s 'http://localhost:7700/stats' \
  -H 'Authorization: Bearer YOUR_API_KEY' | jq '.databaseSize'
```

---

## 4. Search Relevancy Not Matching Expectations

### Symptoms

- Exact matches appear below partial or fuzzy matches.
- Important documents rank lower than less relevant ones.
- Search results seem random or inconsistent.
- Stop words like "the" or "and" pollute results.

### Cause

- The default ranking rules may not match your relevancy requirements.
- Attribute order in `searchableAttributes` defines `attribute` ranking priority — a match in the first listed attribute ranks higher.
- Typo tolerance promotes fuzzy matches that may outrank exact matches in lower-priority attributes.
- Stop words that are not configured inflate result sets with noise.

### Diagnosis

Use `showRankingScore` and `showRankingScoreDetails` to understand why a document ranks where it does:

```bash
curl -X POST 'http://localhost:7700/indexes/products/search' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "q": "wireless headphones",
    "showRankingScore": true,
    "showRankingScoreDetails": true,
    "limit": 5
  }' | jq '.hits[] | {id, name: .name, _rankingScore, _rankingScoreDetails}'
```

The `_rankingScoreDetails` object breaks down the score by each ranking rule, making it clear which rule is pushing a document up or down.

Check current ranking rules:

```bash
curl -s 'http://localhost:7700/indexes/products/settings/ranking-rules' \
  -H 'Authorization: Bearer YOUR_API_KEY' | jq .
```

Check searchableAttributes order:

```bash
curl -s 'http://localhost:7700/indexes/products/settings/searchable-attributes' \
  -H 'Authorization: Bearer YOUR_API_KEY' | jq .
```

### Solution

**1. Order `searchableAttributes` by importance.**

The first attribute has the highest `attribute` ranking weight:

```bash
curl -X PUT 'http://localhost:7700/indexes/products/settings/searchable-attributes' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '["name", "brand", "description", "tags"]'
```

A match in `name` now outranks a match in `description`.

**2. Configure stop words.**

```bash
curl -X PUT 'http://localhost:7700/indexes/products/settings/stop-words' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '["the", "a", "an", "and", "or", "but", "in", "on", "of"]'
```

**3. Use `matchingStrategy` to control result strictness.**

```bash
# "all" — every query term must match (stricter, fewer results)
# "last" — drops the last query terms first if no full match (default, more results)
# "frequency" — drops the least frequent terms first (balances strictness and recall)
curl -X POST 'http://localhost:7700/indexes/products/search' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "q": "wireless noise cancelling headphones",
    "matchingStrategy": "frequency"
  }'
```

**4. Adjust typo tolerance if fuzzy matches overwhelm exact ones.**

```bash
curl -X PATCH 'http://localhost:7700/indexes/products/settings/typo-tolerance' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "minWordSizeForTypos": {
      "oneTypo": 5,
      "twoTypos": 9
    }
  }'
```

---

## 5. Ranking Rules Misconfiguration

### Symptoms

- `sort` parameter in search queries has no effect.
- Custom ranking (e.g., by popularity or rating) does not influence results.
- Results order changes unexpectedly after modifying ranking rules.

### Cause

- The `sort` ranking rule must be present in the ranking rules list for the `sort` search parameter to work.
- Custom ranking rules must reference the correct attribute name and direction.
- Ranking rules are applied in order — rules listed first have higher priority.

### Diagnosis

```bash
# Check current ranking rules
curl -s 'http://localhost:7700/indexes/products/settings/ranking-rules' \
  -H 'Authorization: Bearer YOUR_API_KEY' | jq .
```

Default ranking rules:

```json
["words", "typo", "proximity", "attribute", "sort", "exactness"]
```

### Solution

**1. Ensure `sort` is in the ranking rules.**

If you removed or customized ranking rules and left out `sort`, the `sort` search parameter silently does nothing:

```bash
curl -X PUT 'http://localhost:7700/indexes/products/settings/ranking-rules' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '["words", "typo", "proximity", "attribute", "sort", "exactness"]'
```

Also add the attribute to `sortableAttributes`:

```bash
curl -X PUT 'http://localhost:7700/indexes/products/settings/sortable-attributes' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '["price", "releaseDate", "rating"]'
```

**2. Add custom ranking rules.**

Custom ranking rules use the format `attribute:asc` or `attribute:desc`:

```bash
curl -X PUT 'http://localhost:7700/indexes/products/settings/ranking-rules' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '["words", "typo", "proximity", "attribute", "sort", "exactness", "popularity:desc"]'
```

**3. Common mistakes to avoid.**

| Mistake | Effect | Fix |
|---|---|---|
| Omitting `sort` from ranking rules | `sort` search parameter is ignored | Add `"sort"` back to the rules list |
| Wrong attribute name in custom rule | Rule has no effect (no error thrown) | Verify the attribute exists in your documents |
| Placing custom rule before `words` | Relevancy degrades; popularity overrides text matching | Place custom rules after `exactness` unless you intentionally want them dominant |
| Not adding attribute to `sortableAttributes` | Sorting by that attribute errors | Add attribute to `sortableAttributes` setting |

---

## 6. Filterable Attributes Not Set

### Symptoms

- Search with `filter` parameter returns an error:
  ```
  Attribute `category` is not filterable. Available filterable attributes are: .
  ```
- Facets return empty or error when using `facets` parameter.

### Cause

- Attributes must be explicitly added to `filterableAttributes` before they can be used in `filter` or `facets`. Meilisearch does not build filter indexes by default.
- After adding an attribute to `filterableAttributes`, Meilisearch must reindex to build the filter data structures. The attribute is not filterable until that task completes.

### Diagnosis

```bash
# Check which attributes are currently filterable
curl -s 'http://localhost:7700/indexes/products/settings/filterable-attributes' \
  -H 'Authorization: Bearer YOUR_API_KEY' | jq .

# Check the full settings to see all configured attributes at once
curl -s 'http://localhost:7700/indexes/products/settings' \
  -H 'Authorization: Bearer YOUR_API_KEY' | jq '{filterableAttributes, sortableAttributes, searchableAttributes}'
```

### Solution

```bash
# Add the attribute to filterableAttributes
curl -X PUT 'http://localhost:7700/indexes/products/settings/filterable-attributes' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '["category", "price", "inStock", "brand"]'
```

Wait for the settings update task to complete before issuing filter queries:

```bash
# The response contains a taskUid — poll until succeeded
TASK_UID=$(curl -s -X PUT 'http://localhost:7700/indexes/products/settings/filterable-attributes' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '["category", "price", "inStock", "brand"]' | jq -r '.taskUid')

echo "Waiting for task $TASK_UID..."
while true; do
  STATUS=$(curl -s "http://localhost:7700/tasks/$TASK_UID" \
    -H 'Authorization: Bearer YOUR_API_KEY' | jq -r '.status')
  echo "Status: $STATUS"
  [ "$STATUS" = "succeeded" ] && break
  [ "$STATUS" = "failed" ] && { echo "Task failed!"; break; }
  sleep 2
done
```

---

## 7. API Key Permission Errors

### Symptoms

- `403 Forbidden` on requests that previously worked.
- `401 Unauthorized` — missing or invalid API key.
- Tenant tokens fail with `403` even though the parent key is valid.
- Multi-tenant search returns results from wrong tenant.

### Cause

- API keys have scoped `actions` and `indexes` — a key may have search permission but not document write permission.
- The master key grants all permissions but should never be used in client-side code.
- Tenant tokens (JWTs) expire, reference a revoked parent key, or have malformed claims.

### Diagnosis

```bash
# List all API keys (requires master key)
curl -s 'http://localhost:7700/keys' \
  -H 'Authorization: Bearer YOUR_MASTER_KEY' | jq '.results[] | {uid, name, actions, indexes, expiresAt}'
```

For tenant token issues, decode the JWT to inspect claims:

```bash
# Decode a JWT token (base64 decode the payload)
echo "YOUR_TENANT_TOKEN" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .
```

Check that the `apiKeyUid` in the token payload matches an existing, non-expired key.

### Solution

**1. Create keys with appropriate scopes.**

```bash
# Create a search-only key scoped to specific indexes
curl -X POST 'http://localhost:7700/keys' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_MASTER_KEY' \
  --data-binary '{
    "name": "Frontend Search Key",
    "description": "Search-only access for the products index",
    "actions": ["search"],
    "indexes": ["products"],
    "expiresAt": "2025-12-31T23:59:59Z"
  }'
```

**2. Fix tenant token issues.**

Ensure the tenant token:
- References a valid, non-expired parent key UID (not the key value — the UID).
- Is signed with the parent key's **value** (the API key string, not the UID).
- Has a valid `exp` (expiration) claim that is in the future.
- Contains a `searchRules` claim that matches the intended index scope.

**3. Key rotation strategy.**

```bash
# 1. Create a new key with the same permissions
# 2. Update clients to use the new key
# 3. Delete the old key
curl -X DELETE 'http://localhost:7700/keys/OLD_KEY_UID' \
  -H 'Authorization: Bearer YOUR_MASTER_KEY'
```

**4. Never expose the master key in client-side code.**

The master key should only be used server-side for administration. Generate scoped API keys for all client-facing use.

---

## 8. Docker Volume Data Persistence

### Symptoms

- All indexes and documents disappear after `docker restart` or `docker-compose down && up`.
- Meilisearch starts fresh with no data after container recreation.
- Permission denied errors when Meilisearch tries to write to the data directory.

### Cause

- Without a volume mount, Meilisearch writes data to the container's ephemeral filesystem. Stopping or removing the container destroys the data.
- Incorrect volume mount path — Meilisearch stores data in `/meili_data` inside the container.
- File permission mismatches between the host and container user.

### Diagnosis

```bash
# Check if the container has a volume mounted
docker inspect <container_id> | jq '.[0].Mounts'

# Check if data exists on the host
ls -la /path/to/your/meili_data/

# Check container logs for permission errors
docker logs <container_id> 2>&1 | grep -i "permission\|denied\|error"
```

### Solution

**1. Use a named volume (recommended).**

```yaml
# docker-compose.yml
version: '3.8'
services:
  meilisearch:
    image: getmeili/meilisearch:v1.10
    ports:
      - "7700:7700"
    environment:
      MEILI_MASTER_KEY: 'your-master-key-min-16-bytes'
      MEILI_ENV: 'production'
    volumes:
      - meili_data:/meili_data

volumes:
  meili_data:
```

**2. Use a bind mount if you need direct host access.**

```yaml
volumes:
  - ./data/meili_data:/meili_data
```

Ensure the host directory exists and has correct permissions:

```bash
mkdir -p ./data/meili_data
# Meilisearch runs as UID 1000 by default in the official image
chown -R 1000:1000 ./data/meili_data
```

**3. Docker run with volume.**

```bash
docker run -d \
  --name meilisearch \
  -p 7700:7700 \
  -v meili_data:/meili_data \
  -e MEILI_MASTER_KEY='your-master-key-min-16-bytes' \
  -e MEILI_ENV='production' \
  getmeili/meilisearch:v1.10
```

**4. Verify data persists.**

```bash
docker-compose down
docker-compose up -d
# Data should still be present
curl -s 'http://localhost:7700/indexes' -H 'Authorization: Bearer YOUR_API_KEY' | jq '.results[].uid'
```

---

## 9. Snapshot and Dump Restore Failures

### Symptoms

- `--import-dump` fails with a version compatibility error.
- `--import-snapshot` crashes on startup or reports corruption.
- Restored instance is missing indexes or documents.
- Dump file is unexpectedly large or takes very long to import.

### Cause

- Dumps are version-portable but may not be compatible across major version jumps without an intermediate step.
- Snapshots are exact binary copies of the database — they must match the exact same Meilisearch version.
- File path errors (relative vs absolute) or permission issues prevent Meilisearch from reading the file.
- Corrupted dump/snapshot files from interrupted export or disk issues.

### Diagnosis

```bash
# Check the Meilisearch version
curl -s 'http://localhost:7700/version' \
  -H 'Authorization: Bearer YOUR_API_KEY' | jq .

# Check dump file integrity
ls -lh /path/to/dump.dump
file /path/to/dump.dump
```

### Solution

**1. Create a dump from the running instance.**

```bash
# Trigger dump creation
curl -X POST 'http://localhost:7700/dumps' \
  -H 'Authorization: Bearer YOUR_API_KEY'
# Response contains a taskUid — poll /tasks/{taskUid} until succeeded
# The dump file is created in the dumps/ directory (or MEILI_DUMP_DIR)
```

**2. Import a dump into a fresh instance.**

```bash
# The instance must be started fresh (no existing data)
meilisearch --import-dump /path/to/dump.dump --master-key 'your-master-key'
```

**3. Import a snapshot.**

```bash
# Snapshots require the EXACT same Meilisearch version
meilisearch --import-snapshot /path/to/snapshot.snapshot --master-key 'your-master-key'
```

**4. Handle corrupted files.**

- If a dump is corrupted, try recreating it from the source instance.
- If the source instance is unavailable, check for scheduled snapshots — they are taken periodically if `--schedule-snapshot` was enabled.
- As a last resort, re-index from the original data source.

**5. Dumps vs snapshots — when to use each.**

| Feature | Dump | Snapshot |
|---|---|---|
| Version portable | Yes (within compatibility range) | No (exact version match required) |
| Use case | Migration, version upgrades | Fast backup/restore on same version |
| Contains | Documents, settings, keys, tasks | Full binary database state |
| Import flag | `--import-dump` | `--import-snapshot` |

---

## 10. Version Upgrade Migrations

### Symptoms

- Meilisearch fails to start after upgrading the binary or Docker image.
- Data is incompatible with the new version.
- New features are unavailable even after upgrading.

### Cause

- Meilisearch does not support in-place database upgrades between major or minor versions. The internal storage format changes between versions.
- Skipping versions in a migration can lead to incompatibility.

### Diagnosis

```bash
# Check current version before upgrading
curl -s 'http://localhost:7700/version' \
  -H 'Authorization: Bearer YOUR_API_KEY' | jq .

# Check the release notes for breaking changes
# https://github.com/meilisearch/meilisearch/releases
```

### Solution

**Dump-based migration workflow (recommended):**

```bash
# Step 1: Create a dump from the OLD version
curl -X POST 'http://localhost:7700/dumps' \
  -H 'Authorization: Bearer YOUR_API_KEY'
# Wait for the dump task to complete

# Step 2: Stop the old Meilisearch instance
# (docker-compose down, systemctl stop meilisearch, etc.)

# Step 3: Back up the existing data directory
cp -r /meili_data /meili_data_backup

# Step 4: Clear the data directory for the new version
rm -rf /meili_data/data.ms

# Step 5: Start the NEW version with --import-dump
meilisearch --import-dump /meili_data/dumps/YOUR_DUMP_FILE.dump \
  --master-key 'your-master-key'
```

**Rollback strategy:**

If the upgrade fails:

```bash
# 1. Stop the new version
# 2. Restore the backed-up data directory
cp -r /meili_data_backup/* /meili_data/
# 3. Start the old version binary
```

**Docker upgrade:**

```yaml
# Update the image tag in docker-compose.yml
services:
  meilisearch:
    image: getmeili/meilisearch:v1.10  # was v1.9
```

Always check the [release notes](https://github.com/meilisearch/meilisearch/releases) for breaking changes, deprecated features, and migration instructions specific to your version jump.

---

## 11. Network and Connection Issues

### Symptoms

- `curl: (7) Failed to connect to localhost port 7700: Connection refused`
- Clients can reach Meilisearch from localhost but not from other hosts.
- Reverse proxy returns 502 Bad Gateway.
- Browser-based search fails with CORS errors.

### Cause

- Meilisearch is not running or has crashed.
- Meilisearch is bound to `127.0.0.1` (default) and not accessible from external hosts.
- A firewall is blocking port 7700.
- Reverse proxy is misconfigured (wrong upstream, missing headers).
- CORS headers are not set for browser-based access.

### Diagnosis

```bash
# Check if Meilisearch is running
pgrep -a meilisearch
# or
systemctl status meilisearch

# Check what address and port it's listening on
ss -tlnp | grep 7700

# Test local connectivity
curl -s 'http://127.0.0.1:7700/health' | jq .
# Expected: {"status": "available"}

# Test external connectivity
curl -s 'http://YOUR_SERVER_IP:7700/health' | jq .

# Check firewall rules (Linux)
sudo iptables -L -n | grep 7700
# or with ufw
sudo ufw status | grep 7700
```

### Solution

**1. Bind to all interfaces (for non-localhost access).**

```bash
# Allow connections from any interface
export MEILI_HTTP_ADDR='0.0.0.0:7700'
meilisearch --master-key 'your-master-key'
```

> **Security note:** Only bind to `0.0.0.0` if the server is behind a firewall or reverse proxy. Never expose Meilisearch directly to the public internet without authentication.

**2. Open firewall port.**

```bash
# UFW
sudo ufw allow 7700/tcp

# iptables
sudo iptables -A INPUT -p tcp --dport 7700 -j ACCEPT
```

**3. Configure reverse proxy (Nginx example).**

```nginx
upstream meilisearch {
    server 127.0.0.1:7700;
}

server {
    listen 443 ssl;
    server_name search.example.com;

    location / {
        proxy_pass http://meilisearch;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Increase timeout for large imports
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;

        # Increase max body size for document uploads
        client_max_body_size 100M;
    }
}
```

**4. Fix CORS errors.**

Meilisearch does not natively handle CORS. Configure CORS at the reverse proxy level:

```nginx
location / {
    # CORS headers
    add_header 'Access-Control-Allow-Origin' 'https://your-frontend.com' always;
    add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, PATCH, DELETE, OPTIONS' always;
    add_header 'Access-Control-Allow-Headers' 'Content-Type, Authorization' always;

    if ($request_method = 'OPTIONS') {
        return 204;
    }

    proxy_pass http://meilisearch;
}
```

---

## 12. Payload Too Large

### Symptoms

- HTTP `413 Payload Too Large` response when adding documents.
- Error message: `The provided payload reached the size limit.`
- Large batch imports fail immediately without processing.

### Cause

- Meilisearch enforces a default payload size limit of approximately 100 MiB.
- If a reverse proxy sits in front of Meilisearch, its own body size limit may be lower (Nginx defaults to 1 MiB).

### Diagnosis

```bash
# Check the size of your payload
ls -lh documents.json

# Check Meilisearch logs for payload size errors
journalctl -u meilisearch | grep -i "payload\|size\|limit"
```

### Solution

**1. Increase the Meilisearch payload limit.**

```bash
# Set to 200 MiB (value is in bytes)
export MEILI_HTTP_PAYLOAD_SIZE_LIMIT=209715200
meilisearch --master-key 'your-master-key'
```

Or in a Docker environment:

```yaml
services:
  meilisearch:
    image: getmeili/meilisearch:v1.10
    environment:
      MEILI_HTTP_PAYLOAD_SIZE_LIMIT: '209715200'
      MEILI_MASTER_KEY: 'your-master-key'
```

**2. Increase the reverse proxy limit.**

For Nginx:

```nginx
client_max_body_size 200M;
```

For Caddy:

```
request_body {
    max_size 200MB
}
```

**3. Split large batches (preferred approach).**

Rather than increasing limits, split payloads into smaller batches:

```bash
# Split a large NDJSON file into 30,000-line chunks
split -l 30000 large_dataset.ndjson chunk_

for file in chunk_*; do
  echo "Uploading $file ($(wc -l < "$file") docs)..."
  curl -X POST 'http://localhost:7700/indexes/products/documents' \
    -H 'Content-Type: application/x-ndjson' \
    -H 'Authorization: Bearer YOUR_API_KEY' \
    --data-binary @"$file"
  sleep 1  # Brief pause between batches
done

# Clean up chunk files
rm chunk_*
```

Splitting is generally better than raising limits because it reduces per-request memory usage and makes failures easier to retry.

---

## Quick Diagnostic Checklist

When something goes wrong, run through these checks first:

```bash
# 1. Is Meilisearch running and healthy?
curl -s 'http://localhost:7700/health' | jq .

# 2. What version is running?
curl -s 'http://localhost:7700/version' -H 'Authorization: Bearer KEY' | jq .

# 3. Are there failed tasks?
curl -s 'http://localhost:7700/tasks?statuses=failed&limit=5' \
  -H 'Authorization: Bearer KEY' | jq '.results[] | {uid, type, error}'

# 4. What are the index stats?
curl -s 'http://localhost:7700/stats' -H 'Authorization: Bearer KEY' | jq .

# 5. What are the current settings?
curl -s 'http://localhost:7700/indexes/YOUR_INDEX/settings' \
  -H 'Authorization: Bearer KEY' | jq .
```
