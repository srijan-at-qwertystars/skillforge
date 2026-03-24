#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# setup-elk-stack.sh
#
# Sets up a complete ELK (Elasticsearch, Logstash, Kibana) stack with Filebeat
# using Docker Compose. Security (TLS + authentication) is enabled by default.
#
# Prerequisites:
#   - Docker and Docker Compose (v2) installed
#
# Usage:
#   ./setup-elk-stack.sh --output-dir /path/to/stack --password <elastic_password>
#   ./setup-elk-stack.sh --output-dir ./elk --version 8.17.0 --password s3cret
#   ./setup-elk-stack.sh --help
#
# Flags:
#   --output-dir   Directory where the stack files will be created (required)
#   --version      Elasticsearch / stack version (default: 8.17.0)
#   --password     Password for the 'elastic' superuser (required)
#   --help         Show this help message
###############################################################################

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
SCRIPT_NAME="$(basename "$0")"
OUTPUT_DIR=""
ES_VERSION="8.17.0"
ELASTIC_PASSWORD=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()   { printf '[%s] %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$*"; }
error() { log "ERROR: $*" >&2; }
die()   { error "$@"; exit 1; }

usage() {
    sed -n '/^# Usage:/,/^###/p' "$0" | head -n -1 | sed 's/^# \?//'
    echo ""
    echo "Flags:"
    echo "  --output-dir   Directory where the stack files will be created (required)"
    echo "  --version      Elasticsearch / stack version (default: 8.17.0)"
    echo "  --password     Password for the 'elastic' superuser (required)"
    echo "  --help         Show this help message"
    exit 0
}

cleanup() {
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        error "Setup failed (exit code $rc). Partial files may remain in ${OUTPUT_DIR:-<unset>}."
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output-dir)
                OUTPUT_DIR="${2:?'--output-dir requires a value'}"
                shift 2
                ;;
            --version)
                ES_VERSION="${2:?'--version requires a value'}"
                shift 2
                ;;
            --password)
                ELASTIC_PASSWORD="${2:?'--password requires a value'}"
                shift 2
                ;;
            --help|-h)
                usage
                ;;
            *)
                die "Unknown option: $1. Use --help for usage."
                ;;
        esac
    done

    [[ -n "$OUTPUT_DIR" ]]       || die "--output-dir is required"
    [[ -n "$ELASTIC_PASSWORD" ]] || die "--password is required"
}

# ---------------------------------------------------------------------------
# Directory scaffolding
# ---------------------------------------------------------------------------
create_directories() {
    log "Creating directory structure under ${OUTPUT_DIR} ..."
    mkdir -p "${OUTPUT_DIR}"/{certs,logstash/pipeline,filebeat,esdata01,esdata02,esdata03}
}

# ---------------------------------------------------------------------------
# TLS certificate generation
# ---------------------------------------------------------------------------
generate_certificates() {
    log "Generating TLS certificates ..."

    # instances.yml describes the nodes that need certificates
    cat > "${OUTPUT_DIR}/certs/instances.yml" <<'INSTANCES'
instances:
  - name: es01
    dns: [es01, localhost]
    ip: [127.0.0.1]
  - name: es02
    dns: [es02, localhost]
    ip: [127.0.0.1]
  - name: es03
    dns: [es03, localhost]
    ip: [127.0.0.1]
  - name: kibana
    dns: [kibana, localhost]
    ip: [127.0.0.1]
  - name: logstash
    dns: [logstash, localhost]
    ip: [127.0.0.1]
  - name: filebeat
    dns: [filebeat, localhost]
    ip: [127.0.0.1]
INSTANCES

    local certs_dir
    certs_dir="$(cd "${OUTPUT_DIR}/certs" && pwd)"

    # Generate CA
    docker run --rm \
        -v "${certs_dir}:/certs" \
        -w /certs \
        "docker.elastic.co/elasticsearch/elasticsearch:${ES_VERSION}" \
        bin/elasticsearch-certutil ca \
            --silent --pem \
            --out /certs/ca.zip

    (cd "${certs_dir}" && unzip -o ca.zip && rm -f ca.zip)

    # Generate node certificates signed by the CA
    docker run --rm \
        -v "${certs_dir}:/certs" \
        -w /certs \
        "docker.elastic.co/elasticsearch/elasticsearch:${ES_VERSION}" \
        bin/elasticsearch-certutil cert \
            --silent --pem \
            --ca-cert /certs/ca/ca.crt \
            --ca-key  /certs/ca/ca.key \
            --in      /certs/instances.yml \
            --out     /certs/certs.zip

    (cd "${certs_dir}" && unzip -o certs.zip && rm -f certs.zip)

    log "Certificates generated successfully."
}

# ---------------------------------------------------------------------------
# Docker Compose file
# ---------------------------------------------------------------------------
write_docker_compose() {
    log "Writing docker-compose.yml ..."

    cat > "${OUTPUT_DIR}/docker-compose.yml" <<COMPOSE
version: "3.8"

services:
  # -------------------------------------------------------------------------
  # Elasticsearch nodes
  # -------------------------------------------------------------------------
  es01:
    image: docker.elastic.co/elasticsearch/elasticsearch:${ES_VERSION}
    container_name: es01
    hostname: es01
    environment:
      - node.name=es01
      - cluster.name=elk-cluster
      - discovery.seed_hosts=es02,es03
      - cluster.initial_master_nodes=es01,es02,es03
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
      - bootstrap.memory_lock=true
      - xpack.security.enabled=true
      - xpack.security.http.ssl.enabled=true
      - xpack.security.http.ssl.key=certs/es01/es01.key
      - xpack.security.http.ssl.certificate=certs/es01/es01.crt
      - xpack.security.http.ssl.certificate_authorities=certs/ca/ca.crt
      - xpack.security.transport.ssl.enabled=true
      - xpack.security.transport.ssl.key=certs/es01/es01.key
      - xpack.security.transport.ssl.certificate=certs/es01/es01.crt
      - xpack.security.transport.ssl.certificate_authorities=certs/ca/ca.crt
      - xpack.security.transport.ssl.verification_mode=certificate
    ulimits:
      memlock: { soft: -1, hard: -1 }
    volumes:
      - ./certs:/usr/share/elasticsearch/config/certs:ro
      - ./esdata01:/usr/share/elasticsearch/data
    ports:
      - "9200:9200"
    networks:
      - elk
    healthcheck:
      test:
        [
          "CMD-SHELL",
          "curl -s --cacert config/certs/ca/ca.crt -u elastic:${ELASTIC_PASSWORD} https://localhost:9200/_cluster/health | grep -qE '\"status\":\"(green|yellow)\"'",
        ]
      interval: 15s
      timeout: 10s
      retries: 30

  es02:
    image: docker.elastic.co/elasticsearch/elasticsearch:${ES_VERSION}
    container_name: es02
    hostname: es02
    environment:
      - node.name=es02
      - cluster.name=elk-cluster
      - discovery.seed_hosts=es01,es03
      - cluster.initial_master_nodes=es01,es02,es03
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
      - bootstrap.memory_lock=true
      - xpack.security.enabled=true
      - xpack.security.http.ssl.enabled=true
      - xpack.security.http.ssl.key=certs/es02/es02.key
      - xpack.security.http.ssl.certificate=certs/es02/es02.crt
      - xpack.security.http.ssl.certificate_authorities=certs/ca/ca.crt
      - xpack.security.transport.ssl.enabled=true
      - xpack.security.transport.ssl.key=certs/es02/es02.key
      - xpack.security.transport.ssl.certificate=certs/es02/es02.crt
      - xpack.security.transport.ssl.certificate_authorities=certs/ca/ca.crt
      - xpack.security.transport.ssl.verification_mode=certificate
    ulimits:
      memlock: { soft: -1, hard: -1 }
    volumes:
      - ./certs:/usr/share/elasticsearch/config/certs:ro
      - ./esdata02:/usr/share/elasticsearch/data
    networks:
      - elk
    healthcheck:
      test:
        [
          "CMD-SHELL",
          "curl -s --cacert config/certs/ca/ca.crt -u elastic:${ELASTIC_PASSWORD} https://localhost:9200/_cluster/health | grep -qE '\"status\":\"(green|yellow)\"'",
        ]
      interval: 15s
      timeout: 10s
      retries: 30

  es03:
    image: docker.elastic.co/elasticsearch/elasticsearch:${ES_VERSION}
    container_name: es03
    hostname: es03
    environment:
      - node.name=es03
      - cluster.name=elk-cluster
      - discovery.seed_hosts=es01,es02
      - cluster.initial_master_nodes=es01,es02,es03
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
      - bootstrap.memory_lock=true
      - xpack.security.enabled=true
      - xpack.security.http.ssl.enabled=true
      - xpack.security.http.ssl.key=certs/es03/es03.key
      - xpack.security.http.ssl.certificate=certs/es03/es03.crt
      - xpack.security.http.ssl.certificate_authorities=certs/ca/ca.crt
      - xpack.security.transport.ssl.enabled=true
      - xpack.security.transport.ssl.key=certs/es03/es03.key
      - xpack.security.transport.ssl.certificate=certs/es03/es03.crt
      - xpack.security.transport.ssl.certificate_authorities=certs/ca/ca.crt
      - xpack.security.transport.ssl.verification_mode=certificate
    ulimits:
      memlock: { soft: -1, hard: -1 }
    volumes:
      - ./certs:/usr/share/elasticsearch/config/certs:ro
      - ./esdata03:/usr/share/elasticsearch/data
    networks:
      - elk
    healthcheck:
      test:
        [
          "CMD-SHELL",
          "curl -s --cacert config/certs/ca/ca.crt -u elastic:${ELASTIC_PASSWORD} https://localhost:9200/_cluster/health | grep -qE '\"status\":\"(green|yellow)\"'",
        ]
      interval: 15s
      timeout: 10s
      retries: 30

  # -------------------------------------------------------------------------
  # Logstash
  # -------------------------------------------------------------------------
  logstash:
    image: docker.elastic.co/logstash/logstash:${ES_VERSION}
    container_name: logstash
    hostname: logstash
    depends_on:
      es01: { condition: service_healthy }
    volumes:
      - ./logstash/pipeline:/usr/share/logstash/pipeline:ro
      - ./certs:/usr/share/logstash/config/certs:ro
    environment:
      - xpack.monitoring.elasticsearch.hosts=https://es01:9200
      - xpack.monitoring.elasticsearch.username=elastic
      - xpack.monitoring.elasticsearch.password=${ELASTIC_PASSWORD}
      - xpack.monitoring.elasticsearch.ssl.certificate_authority=config/certs/ca/ca.crt
    ports:
      - "5044:5044"
      - "9600:9600"
    networks:
      - elk

  # -------------------------------------------------------------------------
  # Kibana
  # -------------------------------------------------------------------------
  kibana:
    image: docker.elastic.co/kibana/kibana:${ES_VERSION}
    container_name: kibana
    hostname: kibana
    depends_on:
      es01: { condition: service_healthy }
    environment:
      - ELASTICSEARCH_HOSTS=https://es01:9200
      - ELASTICSEARCH_USERNAME=kibana_system
      - ELASTICSEARCH_PASSWORD=${ELASTIC_PASSWORD}
      - ELASTICSEARCH_SSL_CERTIFICATEAUTHORITIES=config/certs/ca/ca.crt
      - SERVER_SSL_ENABLED=true
      - SERVER_SSL_CERTIFICATE=config/certs/kibana/kibana.crt
      - SERVER_SSL_KEY=config/certs/kibana/kibana.key
    volumes:
      - ./certs:/usr/share/kibana/config/certs:ro
    ports:
      - "5601:5601"
    networks:
      - elk

  # -------------------------------------------------------------------------
  # Filebeat
  # -------------------------------------------------------------------------
  filebeat:
    image: docker.elastic.co/beats/filebeat:${ES_VERSION}
    container_name: filebeat
    hostname: filebeat
    user: root
    depends_on:
      es01: { condition: service_healthy }
    volumes:
      - ./filebeat/filebeat.yml:/usr/share/filebeat/filebeat.yml:ro
      - ./certs:/usr/share/filebeat/config/certs:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
    networks:
      - elk

networks:
  elk:
    driver: bridge
COMPOSE

    log "docker-compose.yml written."
}

# ---------------------------------------------------------------------------
# Logstash pipeline
# ---------------------------------------------------------------------------
write_logstash_pipeline() {
    log "Writing Logstash pipeline configuration ..."

    cat > "${OUTPUT_DIR}/logstash/pipeline/logstash.conf" <<'PIPELINE'
input {
  beats {
    port => 5044
    ssl  => false
  }
}

filter {
  if [event][module] == "system" {
    grok {
      match => {
        "message" => "%{SYSLOGTIMESTAMP:syslog_timestamp} %{SYSLOGHOST:syslog_hostname} %{DATA:syslog_program}(?:\[%{POSINT:syslog_pid}\])?: %{GREEDYDATA:syslog_message}"
      }
      add_field => [ "received_at", "%{@timestamp}" ]
    }
    date {
      match => [ "syslog_timestamp", "MMM  d HH:mm:ss", "MMM dd HH:mm:ss" ]
    }
  }

  mutate {
    remove_field => [ "[agent][ephemeral_id]", "[agent][id]" ]
  }
}

output {
  elasticsearch {
    hosts    => ["https://es01:9200"]
    user     => "elastic"
    password => "${ELASTIC_PASSWORD}"
    ssl_certificate_authorities => ["/usr/share/logstash/config/certs/ca/ca.crt"]
    index    => "logstash-%{+YYYY.MM.dd}"
  }
}
PIPELINE

    log "Logstash pipeline written."
}

# ---------------------------------------------------------------------------
# Filebeat configuration
# ---------------------------------------------------------------------------
write_filebeat_config() {
    log "Writing Filebeat configuration ..."

    cat > "${OUTPUT_DIR}/filebeat/filebeat.yml" <<'FILEBEAT'
filebeat.inputs:
  - type: container
    paths:
      - /var/lib/docker/containers/*/*.log
    processors:
      - add_docker_metadata:
          host: "unix:///var/run/docker.sock"

filebeat.autodiscover:
  providers:
    - type: docker
      hints.enabled: true

output.logstash:
  hosts: ["logstash:5044"]

logging.level: info
logging.to_files: true
logging.files:
  path: /var/log/filebeat
  name: filebeat
  keepfiles: 7
  permissions: 0644
FILEBEAT

    log "Filebeat configuration written."
}

# ---------------------------------------------------------------------------
# Wait for Elasticsearch and configure built-in user passwords
# ---------------------------------------------------------------------------
wait_for_elasticsearch() {
    log "Starting the stack ..."
    (cd "${OUTPUT_DIR}" && docker compose up -d)

    log "Waiting for Elasticsearch cluster to become healthy ..."
    local retries=0 max_retries=60
    while [[ $retries -lt $max_retries ]]; do
        if docker exec es01 curl -s --cacert config/certs/ca/ca.crt \
            -u "elastic:${ELASTIC_PASSWORD}" \
            "https://localhost:9200/_cluster/health" 2>/dev/null \
            | grep -qE '"status":"(green|yellow)"'; then
            log "Elasticsearch cluster is healthy."
            return 0
        fi
        retries=$((retries + 1))
        sleep 5
    done

    die "Elasticsearch did not become healthy after $((max_retries * 5)) seconds."
}

setup_builtin_passwords() {
    log "Setting passwords for built-in users ..."

    local users=("kibana_system" "logstash_system" "beats_system" "apm_system" "remote_monitoring_user")
    for user in "${users[@]}"; do
        local http_code
        http_code=$(docker exec es01 curl -s -o /dev/null -w "%{http_code}" \
            --cacert config/certs/ca/ca.crt \
            -u "elastic:${ELASTIC_PASSWORD}" \
            -X POST "https://localhost:9200/_security/user/${user}/_password" \
            -H 'Content-Type: application/json' \
            -d "{\"password\": \"${ELASTIC_PASSWORD}\"}")

        if [[ "$http_code" == "200" ]]; then
            log "  ✓ Password set for ${user}"
        else
            error "  ✗ Failed to set password for ${user} (HTTP ${http_code})"
        fi
    done
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    cat <<EOF

================================================================================
  ELK Stack Setup Complete
================================================================================

  Stack version : ${ES_VERSION}
  Location      : ${OUTPUT_DIR}

  Endpoints:
    Elasticsearch : https://localhost:9200  (user: elastic)
    Kibana        : https://localhost:5601
    Logstash      : localhost:5044  (beats input)

  Credentials:
    Username : elastic
    Password : (the password you provided)

  Useful commands:
    cd ${OUTPUT_DIR}
    docker compose ps          # check service status
    docker compose logs -f     # tail all logs
    docker compose down        # stop the stack
    docker compose down -v     # stop and remove volumes

================================================================================
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    create_directories
    generate_certificates
    write_docker_compose
    write_logstash_pipeline
    write_filebeat_config
    wait_for_elasticsearch
    setup_builtin_passwords
    print_summary
}

main "$@"
