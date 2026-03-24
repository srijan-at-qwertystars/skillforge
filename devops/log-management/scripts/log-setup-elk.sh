#!/usr/bin/env bash
# =============================================================================
# log-setup-elk.sh — Docker Compose ELK Stack Setup
# =============================================================================
# Sets up a local ELK stack (Elasticsearch + Logstash + Kibana) with:
#   - Preconfigured index templates for structured JSON logs
#   - ILM (Index Lifecycle Management) policy
#   - Logstash pipeline for JSON and syslog input
#   - Kibana index patterns and sample dashboard
#
# Usage:
#   ./log-setup-elk.sh [OPTIONS]
#
# Options:
#   --dir DIR          Output directory (default: ./elk-stack)
#   --es-version VER   Elasticsearch version (default: 8.14.0)
#   --start            Start the stack after generating files
#   --clean            Remove existing directory before setup
#   --help             Show this help message
#
# Requirements: docker, docker-compose (or docker compose plugin)
#
# Examples:
#   ./log-setup-elk.sh --dir /opt/elk --start
#   ./log-setup-elk.sh --es-version 8.13.0 --clean --start
# =============================================================================
set -euo pipefail

# Defaults
OUTPUT_DIR="./elk-stack"
ES_VERSION="8.14.0"
START_STACK=false
CLEAN=false

usage() {
    sed -n '/^# Usage:/,/^# =====/p' "$0" | head -n -1 | sed 's/^# //'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)       OUTPUT_DIR="$2"; shift 2 ;;
        --es-version) ES_VERSION="$2"; shift 2 ;;
        --start)     START_STACK=true; shift ;;
        --clean)     CLEAN=true; shift ;;
        --help|-h)   usage ;;
        *)           echo "Unknown option: $1"; usage ;;
    esac
done

if $CLEAN && [[ -d "$OUTPUT_DIR" ]]; then
    echo "🧹 Cleaning existing directory: $OUTPUT_DIR"
    rm -rf "$OUTPUT_DIR"
fi

echo "📁 Creating ELK stack in: $OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"/{logstash/pipeline,elasticsearch,kibana,filebeat}

# ---- Docker Compose ----
cat > "$OUTPUT_DIR/docker-compose.yml" << 'COMPOSE'
version: "3.8"

services:
  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:${ES_VERSION:-8.14.0}
    container_name: elk-elasticsearch
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      - xpack.security.http.ssl.enabled=false
      - "ES_JAVA_OPTS=-Xms1g -Xmx1g"
      - cluster.name=elk-logs
      - bootstrap.memory_lock=true
    ulimits:
      memlock: { soft: -1, hard: -1 }
      nofile: { soft: 65536, hard: 65536 }
    volumes:
      - es-data:/usr/share/elasticsearch/data
    ports:
      - "9200:9200"
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:9200/_cluster/health || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 30
    deploy:
      resources:
        limits: { memory: 2g }
        reservations: { memory: 1g }
    networks:
      - elk

  logstash:
    image: docker.elastic.co/logstash/logstash:${ES_VERSION:-8.14.0}
    container_name: elk-logstash
    volumes:
      - ./logstash/pipeline:/usr/share/logstash/pipeline:ro
    ports:
      - "5044:5044"   # Beats input
      - "5514:5514"   # Syslog input
      - "9600:9600"   # Monitoring API
    environment:
      - "LS_JAVA_OPTS=-Xms512m -Xmx512m"
    depends_on:
      elasticsearch:
        condition: service_healthy
    deploy:
      resources:
        limits: { memory: 1g }
    networks:
      - elk

  kibana:
    image: docker.elastic.co/kibana/kibana:${ES_VERSION:-8.14.0}
    container_name: elk-kibana
    environment:
      - ELASTICSEARCH_HOSTS=http://elasticsearch:9200
      - xpack.security.enabled=false
    ports:
      - "5601:5601"
    depends_on:
      elasticsearch:
        condition: service_healthy
    deploy:
      resources:
        limits: { memory: 1g }
    networks:
      - elk

volumes:
  es-data:
    driver: local

networks:
  elk:
    driver: bridge
COMPOSE

# ---- Logstash Pipeline ----
cat > "$OUTPUT_DIR/logstash/pipeline/logstash.conf" << 'LOGSTASH'
input {
  # Beats input (Filebeat, Metricbeat)
  beats {
    port => 5044
  }

  # Syslog input
  syslog {
    port => 5514
    type => "syslog"
  }

  # TCP JSON input (for direct shipping)
  tcp {
    port => 5000
    codec => json_lines
    type => "json-tcp"
  }
}

filter {
  # Parse JSON logs
  if [message] =~ /^\{/ {
    json {
      source => "message"
      skip_on_invalid_json => true
    }
  }

  # Normalize log level
  if [level] {
    mutate {
      lowercase => ["level"]
    }
  }

  # Parse timestamp
  if [timestamp] {
    date {
      match => ["timestamp", "ISO8601", "yyyy-MM-dd HH:mm:ss.SSS", "UNIX_MS"]
      target => "@timestamp"
      remove_field => ["timestamp"]
    }
  }

  # Add environment metadata
  mutate {
    add_field => { "[@metadata][target_index]" => "logs-%{[service]:unknown}-%{+YYYY.MM.dd}" }
  }

  # Syslog-specific processing
  if [type] == "syslog" {
    mutate {
      add_field => { "[@metadata][target_index]" => "syslog-%{+YYYY.MM.dd}" }
    }
  }
}

output {
  elasticsearch {
    hosts => ["http://elasticsearch:9200"]
    index => "%{[@metadata][target_index]}"
    manage_template => false
  }

  # Debug output (disable in production)
  # stdout { codec => rubydebug }
}
LOGSTASH

# ---- Setup script for index templates and ILM ----
cat > "$OUTPUT_DIR/setup-indices.sh" << 'SETUP'
#!/usr/bin/env bash
# Wait for Elasticsearch and configure index templates + ILM
set -euo pipefail
ES_URL="${ES_URL:-http://localhost:9200}"

echo "⏳ Waiting for Elasticsearch..."
until curl -sf "$ES_URL/_cluster/health" > /dev/null 2>&1; do
    sleep 2
done
echo "✅ Elasticsearch is ready"

# ILM Policy
echo "📋 Creating ILM policy..."
curl -sf -X PUT "$ES_URL/_ilm/policy/logs-lifecycle" \
  -H 'Content-Type: application/json' -d '{
  "policy": {
    "phases": {
      "hot": {
        "actions": {
          "rollover": { "max_size": "30gb", "max_age": "7d" }
        }
      },
      "warm": {
        "min_age": "30d",
        "actions": {
          "shrink": { "number_of_shards": 1 },
          "forcemerge": { "max_num_segments": 1 }
        }
      },
      "cold": {
        "min_age": "90d",
        "actions": {
          "freeze": {}
        }
      },
      "delete": {
        "min_age": "365d",
        "actions": { "delete": {} }
      }
    }
  }
}'
echo ""

# Index Template
echo "📋 Creating index template..."
curl -sf -X PUT "$ES_URL/_index_template/logs-template" \
  -H 'Content-Type: application/json' -d '{
  "index_patterns": ["logs-*"],
  "priority": 100,
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 0,
      "index.lifecycle.name": "logs-lifecycle",
      "index.mapping.total_fields.limit": 2000,
      "index.refresh_interval": "5s"
    },
    "mappings": {
      "dynamic": "runtime",
      "properties": {
        "@timestamp": { "type": "date" },
        "level": { "type": "keyword" },
        "message": { "type": "text" },
        "service": { "type": "keyword" },
        "environment": { "type": "keyword" },
        "trace_id": { "type": "keyword" },
        "span_id": { "type": "keyword" },
        "request_id": { "type": "keyword" },
        "duration_ms": { "type": "float" },
        "status": { "type": "integer" },
        "error": {
          "properties": {
            "type": { "type": "keyword" },
            "message": { "type": "text" },
            "stack": { "type": "text", "index": false }
          }
        }
      }
    }
  }
}'
echo ""

# Syslog Template
echo "📋 Creating syslog index template..."
curl -sf -X PUT "$ES_URL/_index_template/syslog-template" \
  -H 'Content-Type: application/json' -d '{
  "index_patterns": ["syslog-*"],
  "priority": 100,
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 0,
      "index.lifecycle.name": "logs-lifecycle"
    },
    "mappings": {
      "properties": {
        "@timestamp": { "type": "date" },
        "host": { "type": "keyword" },
        "program": { "type": "keyword" },
        "severity": { "type": "keyword" },
        "facility": { "type": "keyword" },
        "message": { "type": "text" }
      }
    }
  }
}'
echo ""

echo "✅ Index templates and ILM policy configured"
echo ""
echo "📊 Kibana: http://localhost:5601"
echo "🔍 Elasticsearch: http://localhost:9200"
echo "📡 Logstash Beats: localhost:5044"
echo "📡 Logstash Syslog: localhost:5514"
SETUP
chmod +x "$OUTPUT_DIR/setup-indices.sh"

# ---- Filebeat config example ----
cat > "$OUTPUT_DIR/filebeat/filebeat.yml" << 'FILEBEAT'
filebeat.inputs:
  - type: log
    enabled: true
    paths:
      - /var/log/app/*.log
      - /var/log/app/*.json
    json.keys_under_root: true
    json.overwrite_keys: true
    json.add_error_key: true
    fields:
      environment: production
    fields_under_root: true

  - type: container
    paths:
      - /var/lib/docker/containers/*/*.log
    json.keys_under_root: true

output.logstash:
  hosts: ["logstash:5044"]
  bulk_max_size: 2048

logging.level: info
logging.to_files: true
FILEBEAT

echo "✅ ELK stack files generated in: $OUTPUT_DIR"
echo ""
echo "Files created:"
find "$OUTPUT_DIR" -type f | sort | sed "s|$OUTPUT_DIR/|  |"
echo ""
echo "Next steps:"
echo "  cd $OUTPUT_DIR"
echo "  docker compose up -d"
echo "  ./setup-indices.sh        # After ES is healthy"
echo "  open http://localhost:5601 # Kibana"

if $START_STACK; then
    echo ""
    echo "🚀 Starting ELK stack..."
    cd "$OUTPUT_DIR"
    ES_VERSION="$ES_VERSION" docker compose up -d
    echo "⏳ Waiting for Elasticsearch to be healthy..."
    sleep 10
    ./setup-indices.sh
fi
