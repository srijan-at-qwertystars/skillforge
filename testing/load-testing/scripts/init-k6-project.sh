#!/bin/bash
# =============================================================================
# init-k6-project.sh — Initialize a k6 load testing project
#
# Usage:
#   ./init-k6-project.sh [project-name]
#
# Creates:
#   - Directory structure for k6 tests
#   - Starter test script with thresholds
#   - Makefile with common commands
#   - Docker Compose for Grafana + InfluxDB monitoring
#   - Sample test data CSV
#   - .env template
#
# Prerequisites:
#   - Docker & Docker Compose (for monitoring stack)
#   - k6 will be installed if not present
# =============================================================================

set -euo pipefail

PROJECT_NAME="${1:-load-tests}"
PROJECT_DIR="$(pwd)/${PROJECT_NAME}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Check/Install k6 ---
install_k6() {
  if command -v k6 &>/dev/null; then
    info "k6 already installed: $(k6 version)"
    return
  fi

  info "Installing k6..."
  if [[ "$(uname)" == "Linux" ]]; then
    if command -v apt-get &>/dev/null; then
      sudo gpg -k >/dev/null 2>&1 || true
      sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
        --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D68 2>/dev/null
      echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | \
        sudo tee /etc/apt/sources.list.d/k6.list >/dev/null
      sudo apt-get update -qq && sudo apt-get install -y -qq k6
    elif command -v yum &>/dev/null; then
      sudo yum install -y https://dl.k6.io/rpm/repo.rpm 2>/dev/null
      sudo yum install -y k6
    else
      warn "Cannot auto-install k6. Install manually: https://k6.io/docs/get-started/installation/"
    fi
  elif [[ "$(uname)" == "Darwin" ]]; then
    if command -v brew &>/dev/null; then
      brew install k6
    else
      warn "Install Homebrew first, then run: brew install k6"
    fi
  else
    warn "Unsupported OS. Install k6 manually: https://k6.io/docs/get-started/installation/"
  fi

  if command -v k6 &>/dev/null; then
    info "k6 installed: $(k6 version)"
  else
    warn "k6 installation skipped — install manually before running tests"
  fi
}

# --- Create directory structure ---
create_structure() {
  info "Creating project: ${PROJECT_DIR}"

  mkdir -p "${PROJECT_DIR}"/{tests/{smoke,load,stress,soak,spike},lib,data,results,reports,baselines,monitoring}

  info "Directory structure created"
}

# --- Create starter test ---
create_starter_test() {
  cat > "${PROJECT_DIR}/tests/load/api-load.js" << 'SCRIPT'
import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.1.0/index.js';

// Custom metrics
const errorRate = new Rate('error_rate');
const apiLatency = new Trend('api_latency');
const requestCount = new Counter('request_count');

// Configuration from environment
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export const options = {
  scenarios: {
    load_test: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '1m', target: 20 },   // ramp up
        { duration: '3m', target: 20 },   // steady state
        { duration: '1m', target: 50 },   // increase load
        { duration: '3m', target: 50 },   // steady state
        { duration: '1m', target: 0 },    // ramp down
      ],
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<500', 'p(99)<1500'],
    http_req_failed: ['rate<0.01'],
    error_rate: ['rate<0.05'],
    checks: ['rate>0.99'],
  },
};

export function setup() {
  // Perform any setup: auth, data provisioning, etc.
  const healthRes = http.get(`${BASE_URL}/health`);
  if (healthRes.status !== 200) {
    throw new Error(`Health check failed: ${healthRes.status}`);
  }
  console.log(`Testing against: ${BASE_URL}`);
  return { startTime: Date.now() };
}

export default function (data) {
  group('API Endpoints', () => {
    // GET request
    const listRes = http.get(`${BASE_URL}/api/items`, {
      tags: { name: 'list-items' },
    });
    check(listRes, {
      'list status 200': (r) => r.status === 200,
      'list response < 500ms': (r) => r.timings.duration < 500,
    });
    errorRate.add(listRes.status !== 200);
    apiLatency.add(listRes.timings.duration, { endpoint: 'list' });
    requestCount.add(1);

    sleep(Math.random() * 2 + 1);

    // POST request
    const createRes = http.post(
      `${BASE_URL}/api/items`,
      JSON.stringify({ name: `item-${__VU}-${__ITER}`, value: Math.random() }),
      { headers: { 'Content-Type': 'application/json' }, tags: { name: 'create-item' } }
    );
    check(createRes, {
      'create status 2xx': (r) => r.status >= 200 && r.status < 300,
    });
    errorRate.add(createRes.status < 200 || createRes.status >= 300);
    apiLatency.add(createRes.timings.duration, { endpoint: 'create' });
    requestCount.add(1);
  });

  sleep(Math.random() * 3 + 1);
}

export function teardown(data) {
  const duration = ((Date.now() - data.startTime) / 1000).toFixed(1);
  console.log(`Test completed in ${duration}s`);
}

export function handleSummary(data) {
  return {
    stdout: textSummary(data, { indent: '  ', enableColors: true }),
    'results/summary.json': JSON.stringify(data, null, 2),
  };
}
SCRIPT

  cat > "${PROJECT_DIR}/tests/smoke/smoke.js" << 'SCRIPT'
import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export const options = {
  vus: 1,
  duration: '30s',
  thresholds: {
    http_req_duration: ['p(95)<1000'],
    http_req_failed: ['rate<0.01'],
    checks: ['rate==1.0'],
  },
};

export default function () {
  const res = http.get(`${BASE_URL}/health`);
  check(res, {
    'health check 200': (r) => r.status === 200,
    'response < 1s': (r) => r.timings.duration < 1000,
  });
}
SCRIPT

  cat > "${PROJECT_DIR}/tests/stress/stress.js" << 'SCRIPT'
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export const options = {
  scenarios: {
    stress: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 50 },
        { duration: '3m', target: 50 },
        { duration: '2m', target: 100 },
        { duration: '3m', target: 100 },
        { duration: '2m', target: 200 },
        { duration: '3m', target: 200 },
        { duration: '2m', target: 0 },
      ],
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<1000'],
    http_req_failed: ['rate<0.05'],
  },
};

export default function () {
  const res = http.get(`${BASE_URL}/api/items`);
  check(res, { 'status 200': (r) => r.status === 200 });
  sleep(Math.random() * 2 + 0.5);
}
SCRIPT

  info "Test scripts created"
}

# --- Create shared library ---
create_lib() {
  cat > "${PROJECT_DIR}/lib/helpers.js" << 'SCRIPT'
import { check } from 'k6';

export function checkResponse(res, name, maxDuration = 500) {
  return check(res, {
    [`${name} status 2xx`]: (r) => r.status >= 200 && r.status < 300,
    [`${name} response < ${maxDuration}ms`]: (r) => r.timings.duration < maxDuration,
  });
}

export function randomInt(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

export function randomItem(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}
SCRIPT

  info "Shared library created"
}

# --- Create sample data ---
create_data() {
  cat > "${PROJECT_DIR}/data/users.csv" << 'CSV'
email,password,role
user1@test.com,password1,user
user2@test.com,password2,user
user3@test.com,password3,admin
user4@test.com,password4,user
user5@test.com,password5,user
CSV

  info "Sample test data created"
}

# --- Create Makefile ---
create_makefile() {
  cat > "${PROJECT_DIR}/Makefile" << 'MAKEFILE'
.PHONY: smoke load stress soak monitoring-up monitoring-down clean help

BASE_URL ?= http://localhost:8080
INFLUXDB_URL ?= http://localhost:8086/k6

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

smoke: ## Run smoke test (quick validation)
	k6 run --env BASE_URL=$(BASE_URL) tests/smoke/smoke.js

load: ## Run load test
	k6 run --env BASE_URL=$(BASE_URL) --out influxdb=$(INFLUXDB_URL) tests/load/api-load.js

stress: ## Run stress test
	k6 run --env BASE_URL=$(BASE_URL) --out influxdb=$(INFLUXDB_URL) tests/stress/stress.js

load-local: ## Run load test without InfluxDB
	k6 run --env BASE_URL=$(BASE_URL) tests/load/api-load.js

monitoring-up: ## Start Grafana + InfluxDB
	docker compose -f monitoring/docker-compose.yml up -d
	@echo "Grafana: http://localhost:3000 (admin/admin)"
	@echo "InfluxDB: http://localhost:8086"

monitoring-down: ## Stop monitoring stack
	docker compose -f monitoring/docker-compose.yml down

clean: ## Remove test results
	rm -rf results/* reports/*

suite: smoke load stress ## Run full test suite (smoke → load → stress)
MAKEFILE

  info "Makefile created"
}

# --- Create Docker Compose for monitoring ---
create_monitoring() {
  cat > "${PROJECT_DIR}/monitoring/docker-compose.yml" << 'COMPOSE'
services:
  influxdb:
    image: influxdb:1.8
    container_name: k6-influxdb
    ports:
      - "8086:8086"
    environment:
      - INFLUXDB_DB=k6
      - INFLUXDB_HTTP_MAX_BODY_SIZE=0
    volumes:
      - influxdb-data:/var/lib/influxdb
    healthcheck:
      test: ["CMD", "influx", "-execute", "SHOW DATABASES"]
      interval: 10s
      timeout: 5s
      retries: 5

  grafana:
    image: grafana/grafana:latest
    container_name: k6-grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning
      - ./grafana/dashboards:/var/lib/grafana/dashboards
    depends_on:
      influxdb:
        condition: service_healthy

volumes:
  influxdb-data:
  grafana-data:
COMPOSE

  # Grafana provisioning
  mkdir -p "${PROJECT_DIR}/monitoring/grafana/provisioning/datasources"
  mkdir -p "${PROJECT_DIR}/monitoring/grafana/provisioning/dashboards"
  mkdir -p "${PROJECT_DIR}/monitoring/grafana/dashboards"

  cat > "${PROJECT_DIR}/monitoring/grafana/provisioning/datasources/influxdb.yml" << 'DATASOURCE'
apiVersion: 1
datasources:
  - name: InfluxDB
    type: influxdb
    access: proxy
    url: http://influxdb:8086
    database: k6
    isDefault: true
DATASOURCE

  cat > "${PROJECT_DIR}/monitoring/grafana/provisioning/dashboards/dashboard.yml" << 'DASHBOARD'
apiVersion: 1
providers:
  - name: 'default'
    orgId: 1
    folder: 'Load Testing'
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
DASHBOARD

  info "Monitoring stack created"
}

# --- Create .env template ---
create_env() {
  cat > "${PROJECT_DIR}/.env.example" << 'ENV'
# Target application
BASE_URL=http://localhost:8080

# Authentication (if needed)
LOAD_TEST_PASSWORD=changeme
API_TOKEN=

# Monitoring
INFLUXDB_URL=http://localhost:8086/k6

# k6 Cloud (optional)
K6_CLOUD_TOKEN=
K6_CLOUD_PROJECT_ID=

# Slack notifications (optional)
SLACK_WEBHOOK_URL=
ENV

  cat > "${PROJECT_DIR}/.gitignore" << 'GITIGNORE'
results/
reports/
.env
node_modules/
*.log
GITIGNORE

  info "Config files created"
}

# --- Create README ---
create_readme() {
  cat > "${PROJECT_DIR}/README.md" << 'README'
# Load Tests

## Quick Start

```bash
# 1. Start monitoring (optional)
make monitoring-up

# 2. Run smoke test
make smoke

# 3. Run load test
make load

# 4. View results in Grafana
open http://localhost:3000
```

## Test Types

| Command | Description | Duration |
|---------|-------------|----------|
| `make smoke` | Quick validation (1 VU, 30s) | ~30s |
| `make load` | Standard load test | ~9min |
| `make stress` | Find breaking point | ~17min |
| `make suite` | Run all tests sequentially | ~27min |

## Configuration

Copy `.env.example` to `.env` and set your values:
```bash
cp .env.example .env
```

## Monitoring

Start Grafana + InfluxDB:
```bash
make monitoring-up
# Grafana: http://localhost:3000 (admin/admin)
```
README

  info "README created"
}

# --- Main ---
main() {
  echo ""
  echo "======================================"
  echo "  k6 Load Testing Project Initializer"
  echo "======================================"
  echo ""

  if [ -d "${PROJECT_DIR}" ]; then
    warn "Directory ${PROJECT_DIR} already exists. Files may be overwritten."
    read -rp "Continue? [y/N] " -n 1 reply
    echo
    [[ ! "$reply" =~ ^[Yy]$ ]] && exit 0
  fi

  install_k6
  create_structure
  create_starter_test
  create_lib
  create_data
  create_makefile
  create_monitoring
  create_env
  create_readme

  echo ""
  info "✅ Project initialized: ${PROJECT_DIR}"
  echo ""
  echo "  Next steps:"
  echo "    cd ${PROJECT_NAME}"
  echo "    cp .env.example .env    # configure your target"
  echo "    make smoke              # run smoke test"
  echo "    make monitoring-up      # start Grafana + InfluxDB"
  echo "    make load               # run load test with monitoring"
  echo ""
}

main
