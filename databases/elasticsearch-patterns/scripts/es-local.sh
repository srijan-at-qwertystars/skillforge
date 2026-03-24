#!/usr/bin/env bash
# =============================================================================
# es-local.sh — Start local Elasticsearch 8.x + Kibana for development
#
# Usage:
#   ./es-local.sh [COMMAND]
#
# Commands:
#   start       Start ES + Kibana containers (default)
#   stop        Stop and remove containers
#   status      Show container status and connectivity
#   seed        Load sample data into ES
#   logs        Tail container logs
#   clean       Stop containers and remove all data volumes
#   shell       Open bash in ES container
#
# Environment Variables:
#   ES_VERSION    Elasticsearch version (default: 8.15.0)
#   ES_PORT       ES HTTP port (default: 9200)
#   KIBANA_PORT   Kibana port (default: 5601)
#   ES_MEM        ES JVM heap (default: 1g)
#
# Examples:
#   ./es-local.sh start
#   ./es-local.sh seed
#   ES_VERSION=8.14.0 ./es-local.sh start
#   ./es-local.sh clean
# =============================================================================

set -euo pipefail

ES_VERSION="${ES_VERSION:-8.15.0}"
ES_PORT="${ES_PORT:-9200}"
KIBANA_PORT="${KIBANA_PORT:-5601}"
ES_MEM="${ES_MEM:-1g}"
CONTAINER_ES="es-dev"
CONTAINER_KIBANA="kibana-dev"
NETWORK_NAME="es-dev-net"

COMMAND="${1:-start}"

wait_for_es() {
  local url="http://localhost:${ES_PORT}"
  local max_wait=60
  local waited=0
  echo -n "Waiting for Elasticsearch"
  while ! curl -s "$url" >/dev/null 2>&1; do
    echo -n "."
    sleep 2
    waited=$((waited + 2))
    if [[ $waited -ge $max_wait ]]; then
      echo ""
      echo "❌ Elasticsearch did not start within ${max_wait}s"
      echo "   Check logs: docker logs ${CONTAINER_ES}"
      exit 1
    fi
  done
  echo " ready!"
}

wait_for_kibana() {
  local url="http://localhost:${KIBANA_PORT}/api/status"
  local max_wait=90
  local waited=0
  echo -n "Waiting for Kibana"
  while ! curl -s "$url" | grep -q '"overall"' 2>/dev/null; do
    echo -n "."
    sleep 3
    waited=$((waited + 3))
    if [[ $waited -ge $max_wait ]]; then
      echo ""
      echo "⚠️  Kibana is still starting (may take a few more seconds)"
      return 0
    fi
  done
  echo " ready!"
}

case "$COMMAND" in
  start)
    echo "🚀 Starting Elasticsearch ${ES_VERSION} + Kibana (dev mode)"
    echo "   ES: http://localhost:${ES_PORT}"
    echo "   Kibana: http://localhost:${KIBANA_PORT}"
    echo ""

    # Create network if not exists
    docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || \
      docker network create "$NETWORK_NAME"

    # Start Elasticsearch
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_ES}$"; then
      echo "ℹ️  Elasticsearch container already running"
    else
      docker rm -f "$CONTAINER_ES" 2>/dev/null || true
      docker run -d \
        --name "$CONTAINER_ES" \
        --net "$NETWORK_NAME" \
        -p "${ES_PORT}:9200" \
        -e "discovery.type=single-node" \
        -e "xpack.security.enabled=false" \
        -e "xpack.security.http.ssl.enabled=false" \
        -e "xpack.security.transport.ssl.enabled=false" \
        -e "ES_JAVA_OPTS=-Xms${ES_MEM} -Xmx${ES_MEM}" \
        -e "cluster.name=es-dev" \
        -e "node.name=dev-node" \
        -e "action.destructive_requires_name=false" \
        -v "es-dev-data:/usr/share/elasticsearch/data" \
        "docker.elastic.co/elasticsearch/elasticsearch:${ES_VERSION}"
      echo "✅ Elasticsearch container started"
    fi

    wait_for_es

    # Start Kibana
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_KIBANA}$"; then
      echo "ℹ️  Kibana container already running"
    else
      docker rm -f "$CONTAINER_KIBANA" 2>/dev/null || true
      docker run -d \
        --name "$CONTAINER_KIBANA" \
        --net "$NETWORK_NAME" \
        -p "${KIBANA_PORT}:5601" \
        -e "ELASTICSEARCH_HOSTS=http://${CONTAINER_ES}:9200" \
        -e "xpack.security.enabled=false" \
        "docker.elastic.co/kibana/kibana:${ES_VERSION}"
      echo "✅ Kibana container started"
    fi

    wait_for_kibana

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Dev environment ready!"
    echo "  Elasticsearch: http://localhost:${ES_PORT}"
    echo "  Kibana:        http://localhost:${KIBANA_PORT}"
    echo "  Security:      DISABLED (dev mode)"
    echo ""
    echo "  Load sample data: $0 seed"
    echo "  Dev tools:     http://localhost:${KIBANA_PORT}/app/dev_tools"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ;;

  stop)
    echo "Stopping containers..."
    docker stop "$CONTAINER_KIBANA" "$CONTAINER_ES" 2>/dev/null || true
    docker rm "$CONTAINER_KIBANA" "$CONTAINER_ES" 2>/dev/null || true
    echo "✅ Containers stopped"
    ;;

  status)
    echo "=== Container Status ==="
    docker ps -a --filter "name=${CONTAINER_ES}" --filter "name=${CONTAINER_KIBANA}" \
      --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    if curl -s "http://localhost:${ES_PORT}" >/dev/null 2>&1; then
      echo "✅ Elasticsearch is reachable at http://localhost:${ES_PORT}"
      curl -s "http://localhost:${ES_PORT}/_cluster/health" | python3 -m json.tool 2>/dev/null || \
        curl -s "http://localhost:${ES_PORT}/_cluster/health"
    else
      echo "❌ Elasticsearch is not reachable"
    fi
    ;;

  seed)
    ES_URL="http://localhost:${ES_PORT}"

    echo "📦 Loading sample data into Elasticsearch..."

    # Create sample products index with mappings
    echo ""
    echo "--- Creating 'products' index ---"
    curl -s -X PUT "${ES_URL}/products" \
      -H "Content-Type: application/json" \
      -d '{
        "settings": {
          "number_of_shards": 1,
          "number_of_replicas": 0,
          "analysis": {
            "analyzer": {
              "autocomplete": {
                "type": "custom",
                "tokenizer": "standard",
                "filter": ["lowercase", "autocomplete_filter"]
              }
            },
            "filter": {
              "autocomplete_filter": {
                "type": "edge_ngram",
                "min_gram": 2,
                "max_gram": 15
              }
            }
          }
        },
        "mappings": {
          "dynamic": "strict",
          "properties": {
            "name":        { "type": "text", "analyzer": "autocomplete", "search_analyzer": "standard" },
            "description": { "type": "text" },
            "category":    { "type": "keyword" },
            "brand":       { "type": "keyword" },
            "price":       { "type": "scaled_float", "scaling_factor": 100 },
            "rating":      { "type": "float" },
            "in_stock":    { "type": "boolean" },
            "tags":        { "type": "keyword" },
            "created_at":  { "type": "date" },
            "location":    { "type": "geo_point" }
          }
        }
      }' | python3 -m json.tool 2>/dev/null || echo "(created)"

    # Bulk insert sample products
    echo ""
    echo "--- Indexing sample products ---"
    curl -s -X POST "${ES_URL}/_bulk" \
      -H "Content-Type: application/x-ndjson" \
      -d '{"index":{"_index":"products","_id":"1"}}
{"name":"MacBook Pro 16","description":"Apple laptop with M3 Max chip, 36GB RAM, 1TB SSD","category":"laptops","brand":"Apple","price":3499.00,"rating":4.8,"in_stock":true,"tags":["laptop","apple","professional"],"created_at":"2024-01-15","location":{"lat":37.3861,"lon":-122.0839}}
{"index":{"_index":"products","_id":"2"}}
{"name":"ThinkPad X1 Carbon","description":"Lenovo business ultrabook, Intel Core i7, 16GB RAM","category":"laptops","brand":"Lenovo","price":1649.00,"rating":4.5,"in_stock":true,"tags":["laptop","lenovo","business"],"created_at":"2024-01-10","location":{"lat":40.7128,"lon":-74.0060}}
{"index":{"_index":"products","_id":"3"}}
{"name":"Sony WH-1000XM5","description":"Wireless noise-cancelling headphones with LDAC","category":"audio","brand":"Sony","price":349.99,"rating":4.7,"in_stock":true,"tags":["headphones","wireless","noise-cancelling"],"created_at":"2024-01-05","location":{"lat":35.6762,"lon":139.6503}}
{"index":{"_index":"products","_id":"4"}}
{"name":"Samsung Galaxy S24 Ultra","description":"Flagship smartphone with AI features, 200MP camera","category":"phones","brand":"Samsung","price":1299.99,"rating":4.6,"in_stock":true,"tags":["phone","samsung","5g","ai"],"created_at":"2024-01-20","location":{"lat":37.5665,"lon":126.9780}}
{"index":{"_index":"products","_id":"5"}}
{"name":"Dell UltraSharp U2723QE","description":"27-inch 4K USB-C hub monitor with IPS Black","category":"monitors","brand":"Dell","price":619.99,"rating":4.4,"in_stock":false,"tags":["monitor","4k","usb-c"],"created_at":"2023-12-01","location":{"lat":32.7767,"lon":-96.7970}}
{"index":{"_index":"products","_id":"6"}}
{"name":"Logitech MX Master 3S","description":"Ergonomic wireless mouse with MagSpeed scroll","category":"peripherals","brand":"Logitech","price":99.99,"rating":4.8,"in_stock":true,"tags":["mouse","wireless","ergonomic"],"created_at":"2024-01-12","location":{"lat":46.2044,"lon":6.1432}}
{"index":{"_index":"products","_id":"7"}}
{"name":"Bose QuietComfort Ultra","description":"Spatial audio earbuds with world-class noise cancellation","category":"audio","brand":"Bose","price":299.00,"rating":4.3,"in_stock":true,"tags":["earbuds","wireless","noise-cancelling"],"created_at":"2024-01-18","location":{"lat":42.3601,"lon":-71.0589}}
{"index":{"_index":"products","_id":"8"}}
{"name":"ASUS ROG Strix G16","description":"Gaming laptop with RTX 4070, 16GB RAM, 165Hz display","category":"laptops","brand":"ASUS","price":1599.99,"rating":4.5,"in_stock":true,"tags":["laptop","gaming","asus"],"created_at":"2024-01-08","location":{"lat":25.0330,"lon":121.5654}}
{"index":{"_index":"products","_id":"9"}}
{"name":"iPad Pro 12.9","description":"Apple tablet with M2 chip, Liquid Retina XDR display","category":"tablets","brand":"Apple","price":1099.00,"rating":4.7,"in_stock":true,"tags":["tablet","apple","professional"],"created_at":"2024-01-03","location":{"lat":37.3861,"lon":-122.0839}}
{"index":{"_index":"products","_id":"10"}}
{"name":"Keychron Q1 Pro","description":"Custom mechanical keyboard with Gateron Jupiter switches, QMK/VIA","category":"peripherals","brand":"Keychron","price":199.00,"rating":4.6,"in_stock":true,"tags":["keyboard","mechanical","wireless"],"created_at":"2024-01-22","location":{"lat":22.3193,"lon":114.1694}}
' | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Indexed {len(d[\"items\"])} docs, errors={d[\"errors\"]}')" 2>/dev/null || echo "(bulk indexed)"

    # Create sample logs index
    echo ""
    echo "--- Creating 'logs-app' index ---"
    curl -s -X PUT "${ES_URL}/logs-app" \
      -H "Content-Type: application/json" \
      -d '{
        "settings": { "number_of_shards": 1, "number_of_replicas": 0 },
        "mappings": {
          "properties": {
            "@timestamp":    { "type": "date" },
            "message":       { "type": "text" },
            "log.level":     { "type": "keyword" },
            "service.name":  { "type": "keyword" },
            "http.method":   { "type": "keyword" },
            "http.status":   { "type": "integer" },
            "duration_ms":   { "type": "integer" }
          }
        }
      }' | python3 -m json.tool 2>/dev/null || echo "(created)"

    echo ""
    echo "--- Indexing sample logs ---"
    curl -s -X POST "${ES_URL}/_bulk" \
      -H "Content-Type: application/x-ndjson" \
      -d '{"index":{"_index":"logs-app"}}
{"@timestamp":"2024-01-22T10:00:01Z","message":"GET /api/products 200 OK","log.level":"info","service.name":"api-gateway","http.method":"GET","http.status":200,"duration_ms":45}
{"index":{"_index":"logs-app"}}
{"@timestamp":"2024-01-22T10:00:02Z","message":"POST /api/orders 201 Created","log.level":"info","service.name":"order-service","http.method":"POST","http.status":201,"duration_ms":120}
{"index":{"_index":"logs-app"}}
{"@timestamp":"2024-01-22T10:00:03Z","message":"GET /api/users/123 500 Internal Server Error","log.level":"error","service.name":"user-service","http.method":"GET","http.status":500,"duration_ms":2500}
{"index":{"_index":"logs-app"}}
{"@timestamp":"2024-01-22T10:00:04Z","message":"GET /api/products/search?q=laptop 200 OK","log.level":"info","service.name":"search-service","http.method":"GET","http.status":200,"duration_ms":85}
{"index":{"_index":"logs-app"}}
{"@timestamp":"2024-01-22T10:00:05Z","message":"POST /api/auth/login 401 Unauthorized","log.level":"warn","service.name":"auth-service","http.method":"POST","http.status":401,"duration_ms":15}
' | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Indexed {len(d[\"items\"])} docs, errors={d[\"errors\"]}')" 2>/dev/null || echo "(bulk indexed)"

    # Refresh
    curl -s -X POST "${ES_URL}/_refresh" > /dev/null

    echo ""
    echo "✅ Sample data loaded!"
    echo ""
    echo "Try these queries in Kibana Dev Tools (http://localhost:${KIBANA_PORT}/app/dev_tools):"
    echo ""
    echo '  GET /products/_search { "query": { "match": { "name": "laptop" } } }'
    echo '  GET /products/_search { "query": { "range": { "price": { "gte": 500, "lte": 1500 } } } }'
    echo '  GET /products/_search { "size": 0, "aggs": { "by_category": { "terms": { "field": "category" } } } }'
    echo '  GET /logs-app/_search { "query": { "term": { "log.level": "error" } } }'
    echo ""
    ;;

  logs)
    docker logs -f "$CONTAINER_ES" --tail 100 2>&1 &
    ES_PID=$!
    docker logs -f "$CONTAINER_KIBANA" --tail 100 2>&1 &
    KIBANA_PID=$!
    trap "kill $ES_PID $KIBANA_PID 2>/dev/null" EXIT
    wait
    ;;

  clean)
    echo "⚠️  This will stop containers and DELETE all data volumes."
    read -rp "Continue? (y/N): " CONFIRM
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && exit 0

    docker stop "$CONTAINER_KIBANA" "$CONTAINER_ES" 2>/dev/null || true
    docker rm "$CONTAINER_KIBANA" "$CONTAINER_ES" 2>/dev/null || true
    docker volume rm es-dev-data 2>/dev/null || true
    docker network rm "$NETWORK_NAME" 2>/dev/null || true
    echo "✅ All containers, volumes, and network removed"
    ;;

  shell)
    docker exec -it "$CONTAINER_ES" /bin/bash
    ;;

  *)
    echo "Usage: $0 {start|stop|status|seed|logs|clean|shell}"
    exit 1
    ;;
esac
