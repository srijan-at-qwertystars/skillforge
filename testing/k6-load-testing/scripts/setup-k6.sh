#!/usr/bin/env bash
#
# setup-k6.sh — Install k6 and scaffold a load testing project structure.
#
# Usage:
#   ./setup-k6.sh [project-dir]
#
# Examples:
#   ./setup-k6.sh                    # scaffold in ./k6-tests
#   ./setup-k6.sh my-load-tests      # scaffold in ./my-load-tests
#
# What it does:
#   1. Detects OS and installs k6 if not present
#   2. Creates a project directory with organized structure
#   3. Generates starter config files, helpers, and a sample test script
#   4. Writes a .env.example for environment configuration
#
set -euo pipefail

PROJECT_DIR="${1:-k6-tests}"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Install k6 ──────────────────────────────────────────────────────────────
install_k6() {
  if command -v k6 &>/dev/null; then
    info "k6 already installed: $(k6 version)"
    return 0
  fi

  info "Installing k6..."
  case "$(uname -s)" in
    Darwin)
      if command -v brew &>/dev/null; then
        brew install k6
      else
        error "Homebrew not found. Install via: https://brew.sh"
        exit 1
      fi
      ;;
    Linux)
      if command -v apt-get &>/dev/null; then
        sudo gpg -k 2>/dev/null || true
        sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
          --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69 2>/dev/null
        echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
          | sudo tee /etc/apt/sources.list.d/k6.list
        sudo apt-get update -qq && sudo apt-get install -y -qq k6
      elif command -v yum &>/dev/null; then
        sudo tee /etc/yum.repos.d/k6.repo <<'EOF'
[k6]
name=k6
baseurl=https://dl.k6.io/rpm
enabled=1
gpgcheck=1
gpgkey=https://dl.k6.io/key.gpg
EOF
        sudo yum install -y k6
      elif command -v snap &>/dev/null; then
        sudo snap install k6
      else
        warn "Cannot detect package manager. Install k6 manually: https://k6.io/docs/get-started/installation/"
        return 1
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      if command -v choco &>/dev/null; then
        choco install k6 -y
      else
        error "Install via: choco install k6 or download from https://github.com/grafana/k6/releases"
        exit 1
      fi
      ;;
    *)
      error "Unsupported OS. Install k6 manually: https://k6.io/docs/get-started/installation/"
      exit 1
      ;;
  esac

  if command -v k6 &>/dev/null; then
    info "k6 installed successfully: $(k6 version)"
  else
    error "k6 installation may have failed. Verify with: k6 version"
  fi
}

# ── Scaffold project ────────────────────────────────────────────────────────
scaffold_project() {
  if [[ -d "$PROJECT_DIR" ]]; then
    warn "Directory '$PROJECT_DIR' already exists. Skipping scaffold."
    return 0
  fi

  info "Creating project structure in '$PROJECT_DIR'..."

  mkdir -p "$PROJECT_DIR"/{scenarios,flows,helpers,config,testdata,results,lib}

  # ── config/environments.js ──
  cat > "$PROJECT_DIR/config/environments.js" << 'ENVJS'
// Environment configuration — select via: k6 run -e ENV=staging script.js
const environments = {
  local: {
    baseUrl: 'http://localhost:3000',
    wsUrl: 'ws://localhost:3000',
    thinkTime: { min: 0.5, max: 1 },
  },
  staging: {
    baseUrl: 'https://staging-api.example.com',
    wsUrl: 'wss://staging-ws.example.com',
    thinkTime: { min: 1, max: 3 },
  },
  production: {
    baseUrl: 'https://api.example.com',
    wsUrl: 'wss://ws.example.com',
    thinkTime: { min: 2, max: 5 },
  },
};

const envName = __ENV.ENV || 'staging';
if (!environments[envName]) {
  throw new Error(`Unknown environment: ${envName}. Valid: ${Object.keys(environments).join(', ')}`);
}
export default environments[envName];
ENVJS

  # ── config/thresholds.js ──
  cat > "$PROJECT_DIR/config/thresholds.js" << 'THRJS'
// Shared threshold definitions
export const defaultThresholds = {
  http_req_duration: ['p(95)<500', 'p(99)<1000'],
  http_req_failed: ['rate<0.01'],
  checks: ['rate>0.95'],
};

export const strictThresholds = {
  ...defaultThresholds,
  http_req_duration: ['p(95)<300', 'p(99)<500'],
  http_req_failed: ['rate<0.001'],
  checks: ['rate>0.99'],
};
THRJS

  # ── helpers/requests.js ──
  cat > "$PROJECT_DIR/helpers/requests.js" << 'REQJS'
import http from 'k6/http';
import env from '../config/environments.js';

export function apiGet(path, token, tags = {}) {
  return http.get(`${env.baseUrl}${path}`, {
    headers: authHeaders(token),
    tags: { name: path, ...tags },
  });
}

export function apiPost(path, body, token, tags = {}) {
  return http.post(`${env.baseUrl}${path}`, JSON.stringify(body), {
    headers: { ...authHeaders(token), 'Content-Type': 'application/json' },
    tags: { name: path, ...tags },
  });
}

function authHeaders(token) {
  return token ? { Authorization: `Bearer ${token}` } : {};
}
REQJS

  # ── helpers/checks.js ──
  cat > "$PROJECT_DIR/helpers/checks.js" << 'CHKJS'
import { check } from 'k6';

export function checkStatus(res, expectedStatus = 200, label = '') {
  const prefix = label ? `${label}: ` : '';
  return check(res, {
    [`${prefix}status is ${expectedStatus}`]: (r) => r.status === expectedStatus,
    [`${prefix}response body not empty`]: (r) => r.body && r.body.length > 0,
  });
}

export function checkJsonResponse(res, field, label = '') {
  const prefix = label ? `${label}: ` : '';
  return check(res, {
    [`${prefix}status 200`]: (r) => r.status === 200,
    [`${prefix}has ${field}`]: (r) => r.json(field) !== undefined,
  });
}
CHKJS

  # ── helpers/data.js ──
  cat > "$PROJECT_DIR/helpers/data.js" << 'DATAJS'
import { SharedArray } from 'k6/data';

export function loadJson(name, filePath) {
  return new SharedArray(name, () => JSON.parse(open(filePath)));
}

export function loadCsv(name, filePath) {
  // Requires: import papaparse from 'https://jslib.k6.io/papaparse/5.1.1/index.js';
  // return new SharedArray(name, () =>
  //   papaparse.parse(open(filePath), { header: true }).data
  // );
  throw new Error('Uncomment and configure CSV parsing in helpers/data.js');
}
DATAJS

  # ── testdata/users.json ──
  cat > "$PROJECT_DIR/testdata/users.json" << 'USRJSON'
[
  { "username": "testuser1", "password": "password1" },
  { "username": "testuser2", "password": "password2" },
  { "username": "testuser3", "password": "password3" },
  { "username": "testuser4", "password": "password4" },
  { "username": "testuser5", "password": "password5" }
]
USRJSON

  # ── scenarios/smoke.js ──
  cat > "$PROJECT_DIR/scenarios/smoke.js" << 'SMOKE'
// Smoke test — minimal load to verify script correctness
import http from 'k6/http';
import { sleep } from 'k6';
import env from '../config/environments.js';
import { checkStatus } from '../helpers/checks.js';

export const options = {
  vus: 1,
  iterations: 5,
  thresholds: {
    http_req_duration: ['p(95)<1000'],
    http_req_failed: ['rate<0.01'],
  },
};

export default function () {
  const res = http.get(`${env.baseUrl}/health`);
  checkStatus(res, 200, 'health');
  sleep(1);
}
SMOKE

  # ── scenarios/load.js ──
  cat > "$PROJECT_DIR/scenarios/load.js" << 'LOAD'
// Load test — normal traffic pattern with ramp-up/plateau/ramp-down
import http from 'k6/http';
import { sleep } from 'k6';
import env from '../config/environments.js';
import { defaultThresholds } from '../config/thresholds.js';
import { checkStatus } from '../helpers/checks.js';
import { loadJson } from '../helpers/data.js';

const users = loadJson('users', '../testdata/users.json');

export const options = {
  scenarios: {
    load: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 50 },
        { duration: '5m', target: 50 },
        { duration: '2m', target: 0 },
      ],
    },
  },
  thresholds: defaultThresholds,
};

export default function () {
  const user = users[__VU % users.length];
  const res = http.get(`${env.baseUrl}/api/data`, {
    headers: { 'X-User': user.username },
    tags: { name: 'GetData' },
  });
  checkStatus(res, 200, 'data');
  sleep(Math.random() * (env.thinkTime.max - env.thinkTime.min) + env.thinkTime.min);
}
LOAD

  # ── .env.example ──
  cat > "$PROJECT_DIR/.env.example" << 'DOTENV'
# k6 environment variables
# Pass via: k6 run -e ENV=staging -e API_KEY=xxx scenarios/load.js
ENV=staging
BASE_URL=https://staging-api.example.com
API_KEY=your-api-key-here
K6_CLOUD_TOKEN=your-cloud-token
K6_INFLUXDB_ADDR=http://localhost:8086/k6
DOTENV

  # ── .gitignore ──
  cat > "$PROJECT_DIR/.gitignore" << 'GITIGNORE'
results/
*.json.gz
.env
node_modules/
GITIGNORE

  info "Project scaffolded at '$PROJECT_DIR':"
  find "$PROJECT_DIR" -type f | sort | sed "s|^|  |"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  echo "═══════════════════════════════════════════"
  echo "  k6 Load Testing — Setup Script"
  echo "═══════════════════════════════════════════"
  echo

  install_k6
  echo
  scaffold_project

  echo
  info "Next steps:"
  echo "  cd $PROJECT_DIR"
  echo "  k6 run scenarios/smoke.js                     # quick validation"
  echo "  k6 run -e ENV=staging scenarios/load.js       # load test"
  echo "  k6 run --out json=results/out.json scenarios/load.js  # with output"
}

main "$@"
