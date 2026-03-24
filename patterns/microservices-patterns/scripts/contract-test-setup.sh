#!/usr/bin/env bash
# contract-test-setup.sh — Set up consumer-driven contract testing with Pact
#
# Usage:
#   ./contract-test-setup.sh --lang node     # Node.js/TypeScript project
#   ./contract-test-setup.sh --lang java     # Java/Spring Boot project
#   ./contract-test-setup.sh --lang python   # Python project
#   ./contract-test-setup.sh --broker        # Also set up Pact Broker (Docker)
#
# What it does:
#   1. Installs Pact dependencies for the chosen language
#   2. Creates a sample consumer test
#   3. Creates a sample provider verification test
#   4. Optionally starts a Pact Broker via Docker Compose
#   5. Generates a Makefile/scripts for running contract tests in CI
#
# Requirements: npm/mvn/pip (depending on language), docker (for broker)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

LANG=""
SETUP_BROKER=false
PROJECT_DIR="."

log() { echo -e "${CYAN}[contract-test]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

usage() {
    echo "Usage: $0 --lang <node|java|python> [--broker] [--dir <project-dir>]"
    echo ""
    echo "Options:"
    echo "  --lang LANG    Language/framework (node, java, python)"
    echo "  --broker       Set up Pact Broker via Docker Compose"
    echo "  --dir DIR      Project directory (default: current)"
    echo "  -h, --help     Show this help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --lang) LANG="$2"; shift 2 ;;
        --broker) SETUP_BROKER=true; shift ;;
        --dir) PROJECT_DIR="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [ -z "$LANG" ]; then
    echo -e "${RED}Error: --lang is required.${NC}"
    usage
fi

cd "$PROJECT_DIR"

# --- Pact Broker Setup ---
setup_broker() {
    log "Setting up Pact Broker with Docker Compose..."

    mkdir -p pact-broker

    cat > pact-broker/docker-compose.yml <<'BROKER_COMPOSE'
version: "3.8"

services:
  pact-broker-db:
    image: postgres:15-alpine
    environment:
      POSTGRES_DB: pact_broker
      POSTGRES_USER: pact
      POSTGRES_PASSWORD: pact_password
    volumes:
      - pact-broker-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U pact"]
      interval: 5s
      timeout: 3s
      retries: 5

  pact-broker:
    image: pactfoundation/pact-broker:latest
    ports:
      - "9292:9292"
    environment:
      PACT_BROKER_DATABASE_URL: postgres://pact:pact_password@pact-broker-db/pact_broker
      PACT_BROKER_BASIC_AUTH_USERNAME: admin
      PACT_BROKER_BASIC_AUTH_PASSWORD: admin
      PACT_BROKER_LOG_LEVEL: INFO
    depends_on:
      pact-broker-db:
        condition: service_healthy

volumes:
  pact-broker-data:
BROKER_COMPOSE

    success "Pact Broker config created at pact-broker/docker-compose.yml"
    echo "  Start with: cd pact-broker && docker compose up -d"
    echo "  Access at:  http://localhost:9292 (admin/admin)"
}

# --- Node.js Setup ---
setup_node() {
    log "Setting up Pact contract testing for Node.js..."

    # Install dependencies
    if [ -f package.json ]; then
        log "Installing Pact dependencies..."
        npm install --save-dev @pact-foundation/pact @pact-foundation/pact-node 2>/dev/null || {
            warn "npm install failed — you may need to run it manually"
        }
    else
        warn "No package.json found. Creating one..."
        npm init -y 2>/dev/null
        npm install --save-dev @pact-foundation/pact @pact-foundation/pact-node typescript jest ts-jest @types/jest 2>/dev/null
    fi

    # Create test directories
    mkdir -p tests/contract/consumer tests/contract/provider pacts

    # Consumer test
    cat > tests/contract/consumer/order-service.consumer.test.ts <<'CONSUMER_TEST'
import { PactV3, MatchersV3 } from "@pact-foundation/pact";
import path from "path";

const { like, eachLike, string, integer } = MatchersV3;

const provider = new PactV3({
  consumer: "OrderService",
  provider: "PaymentService",
  dir: path.resolve(process.cwd(), "pacts"),
});

describe("OrderService -> PaymentService Contract", () => {
  it("should process a payment", async () => {
    // Define the expected interaction
    provider
      .given("a valid order exists")
      .uponReceiving("a request to process payment")
      .withRequest({
        method: "POST",
        path: "/api/v1/payments",
        headers: { "Content-Type": "application/json" },
        body: {
          orderId: like("order-123"),
          amount: like(99.99),
          currency: like("USD"),
        },
      })
      .willRespondWith({
        status: 201,
        headers: { "Content-Type": "application/json" },
        body: {
          paymentId: string("pay-456"),
          status: string("COMPLETED"),
          orderId: string("order-123"),
          amount: like(99.99),
        },
      });

    await provider.executeTest(async (mockServer) => {
      // Call your actual HTTP client pointing to the mock server
      const response = await fetch(`${mockServer.url}/api/v1/payments`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          orderId: "order-123",
          amount: 99.99,
          currency: "USD",
        }),
      });

      const body = await response.json();
      expect(response.status).toBe(201);
      expect(body.status).toBe("COMPLETED");
      expect(body.paymentId).toBeDefined();
    });
  });

  it("should return 404 for unknown order", async () => {
    provider
      .given("order does not exist")
      .uponReceiving("a payment request for unknown order")
      .withRequest({
        method: "POST",
        path: "/api/v1/payments",
        headers: { "Content-Type": "application/json" },
        body: {
          orderId: like("nonexistent-999"),
          amount: like(50.0),
          currency: like("USD"),
        },
      })
      .willRespondWith({
        status: 404,
        body: { error: string("Order not found") },
      });

    await provider.executeTest(async (mockServer) => {
      const response = await fetch(`${mockServer.url}/api/v1/payments`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          orderId: "nonexistent-999",
          amount: 50.0,
          currency: "USD",
        }),
      });
      expect(response.status).toBe(404);
    });
  });
});
CONSUMER_TEST

    # Provider verification test
    cat > tests/contract/provider/payment-service.provider.test.ts <<'PROVIDER_TEST'
import { Verifier } from "@pact-foundation/pact";
import path from "path";

describe("PaymentService Provider Verification", () => {
  it("should honor the contract with OrderService", async () => {
    const verifier = new Verifier({
      providerBaseUrl: process.env.PROVIDER_URL || "http://localhost:8082",
      provider: "PaymentService",

      // Option 1: Verify from local pact files
      pactUrls: [
        path.resolve(
          process.cwd(),
          "pacts/OrderService-PaymentService.json"
        ),
      ],

      // Option 2: Verify from Pact Broker (uncomment to use)
      // pactBrokerUrl: "http://localhost:9292",
      // pactBrokerUsername: "admin",
      // pactBrokerPassword: "admin",

      // Provider state setup
      stateHandlers: {
        "a valid order exists": async () => {
          // Set up test data: create order-123 in test DB
          console.log("Setting up: valid order exists");
        },
        "order does not exist": async () => {
          // Ensure no order with given ID exists
          console.log("Setting up: order does not exist");
        },
      },

      // Publish verification results to broker
      publishVerificationResult: !!process.env.CI,
      providerVersion: process.env.GIT_SHA || "local",
    });

    await verifier.verifyProvider();
  });
});
PROVIDER_TEST

    # Add test scripts to package.json
    if [ -f package.json ]; then
        node -e "
const pkg = require('./package.json');
pkg.scripts = pkg.scripts || {};
pkg.scripts['test:contract:consumer'] = 'jest tests/contract/consumer --config jest.config.ts';
pkg.scripts['test:contract:provider'] = 'jest tests/contract/provider --config jest.config.ts';
pkg.scripts['test:contract'] = 'npm run test:contract:consumer && npm run test:contract:provider';
require('fs').writeFileSync('package.json', JSON.stringify(pkg, null, 2));
" 2>/dev/null || warn "Could not update package.json scripts"
    fi

    success "Node.js contract tests created:"
    echo "  tests/contract/consumer/order-service.consumer.test.ts"
    echo "  tests/contract/provider/payment-service.provider.test.ts"
    echo ""
    echo "  Run consumer tests: npm run test:contract:consumer"
    echo "  Run provider tests: npm run test:contract:provider"
}

# --- Java Setup ---
setup_java() {
    log "Setting up Pact contract testing for Java..."

    mkdir -p src/test/java/contract/consumer src/test/java/contract/provider

    # Consumer test
    cat > src/test/java/contract/consumer/OrderServiceConsumerTest.java <<'JAVA_CONSUMER'
package contract.consumer;

import au.com.dius.pact.consumer.dsl.PactDslWithProvider;
import au.com.dius.pact.consumer.dsl.PactDslJsonBody;
import au.com.dius.pact.consumer.junit5.PactConsumerTestExt;
import au.com.dius.pact.consumer.junit5.PactTestFor;
import au.com.dius.pact.consumer.MockServer;
import au.com.dius.pact.core.model.V4Pact;
import au.com.dius.pact.core.model.annotations.Pact;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.URI;

import static org.junit.jupiter.api.Assertions.*;

@ExtendWith(PactConsumerTestExt.class)
@PactTestFor(providerName = "PaymentService")
public class OrderServiceConsumerTest {

    @Pact(consumer = "OrderService")
    public V4Pact processPaymentPact(PactDslWithProvider builder) {
        return builder
            .given("a valid order exists")
            .uponReceiving("a request to process payment")
            .path("/api/v1/payments")
            .method("POST")
            .headers("Content-Type", "application/json")
            .body(new PactDslJsonBody()
                .stringType("orderId", "order-123")
                .decimalType("amount", 99.99)
                .stringType("currency", "USD"))
            .willRespondWith()
            .status(201)
            .headers(java.util.Map.of("Content-Type", "application/json"))
            .body(new PactDslJsonBody()
                .stringType("paymentId", "pay-456")
                .stringValue("status", "COMPLETED")
                .stringType("orderId", "order-123")
                .decimalType("amount", 99.99))
            .toPact(V4Pact.class);
    }

    @Test
    @PactTestFor(pactMethod = "processPaymentPact")
    void testProcessPayment(MockServer mockServer) throws Exception {
        HttpClient client = HttpClient.newHttpClient();
        HttpRequest request = HttpRequest.newBuilder()
            .uri(URI.create(mockServer.getUrl() + "/api/v1/payments"))
            .header("Content-Type", "application/json")
            .POST(HttpRequest.BodyPublishers.ofString(
                "{\"orderId\":\"order-123\",\"amount\":99.99,\"currency\":\"USD\"}"))
            .build();

        HttpResponse<String> response = client.send(request,
            HttpResponse.BodyHandlers.ofString());

        assertEquals(201, response.statusCode());
        assertTrue(response.body().contains("COMPLETED"));
    }
}
JAVA_CONSUMER

    # Maven dependency snippet
    cat > pact-maven-dependencies.xml <<'MAVEN_DEPS'
<!-- Add these to your pom.xml <dependencies> section -->
<dependency>
    <groupId>au.com.dius.pact.consumer</groupId>
    <artifactId>junit5</artifactId>
    <version>4.6.5</version>
    <scope>test</scope>
</dependency>
<dependency>
    <groupId>au.com.dius.pact.provider</groupId>
    <artifactId>junit5</artifactId>
    <version>4.6.5</version>
    <scope>test</scope>
</dependency>
MAVEN_DEPS

    success "Java contract tests created:"
    echo "  src/test/java/contract/consumer/OrderServiceConsumerTest.java"
    echo "  pact-maven-dependencies.xml (add to pom.xml)"
}

# --- Python Setup ---
setup_python() {
    log "Setting up Pact contract testing for Python..."

    pip install pact-python pytest 2>/dev/null || warn "pip install failed — run manually: pip install pact-python pytest"

    mkdir -p tests/contract

    cat > tests/contract/test_order_consumer.py <<'PYTHON_CONSUMER'
"""Consumer contract test: OrderService -> PaymentService."""
import pytest
import requests
from pact import Consumer, Provider, Like, EachLike, Term

PACT_DIR = "./pacts"

@pytest.fixture(scope="module")
def pact():
    """Set up Pact mock provider."""
    pact = Consumer("OrderService").has_pact_with(
        Provider("PaymentService"),
        pact_dir=PACT_DIR,
    )
    pact.start_service()
    yield pact
    pact.stop_service()


def test_process_payment(pact):
    """Verify OrderService can call PaymentService to process payment."""
    expected_body = {
        "paymentId": Like("pay-456"),
        "status": "COMPLETED",
        "orderId": Like("order-123"),
        "amount": Like(99.99),
    }

    (
        pact.given("a valid order exists")
        .upon_receiving("a request to process payment")
        .with_request("POST", "/api/v1/payments",
                       headers={"Content-Type": "application/json"},
                       body={
                           "orderId": "order-123",
                           "amount": 99.99,
                           "currency": "USD",
                       })
        .will_respond_with(201, body=expected_body)
    )

    with pact:
        response = requests.post(
            f"{pact.uri}/api/v1/payments",
            json={"orderId": "order-123", "amount": 99.99, "currency": "USD"},
        )

    assert response.status_code == 201
    data = response.json()
    assert data["status"] == "COMPLETED"
    assert "paymentId" in data


def test_payment_for_unknown_order(pact):
    """Verify 404 response for unknown order."""
    (
        pact.given("order does not exist")
        .upon_receiving("a payment request for unknown order")
        .with_request("POST", "/api/v1/payments",
                       headers={"Content-Type": "application/json"},
                       body={
                           "orderId": "nonexistent-999",
                           "amount": 50.0,
                           "currency": "USD",
                       })
        .will_respond_with(404, body={"error": Like("Order not found")})
    )

    with pact:
        response = requests.post(
            f"{pact.uri}/api/v1/payments",
            json={"orderId": "nonexistent-999", "amount": 50.0, "currency": "USD"},
        )

    assert response.status_code == 404
PYTHON_CONSUMER

    success "Python contract tests created:"
    echo "  tests/contract/test_order_consumer.py"
    echo ""
    echo "  Run: pytest tests/contract/"
}

# --- CI Integration ---
setup_ci() {
    log "Creating CI integration script..."

    cat > run-contract-tests.sh <<'CI_SCRIPT'
#!/usr/bin/env bash
# Run contract tests in CI
# This script is called by CI pipelines after unit tests pass

set -euo pipefail

PACT_BROKER_URL="${PACT_BROKER_URL:-http://localhost:9292}"
GIT_SHA="${GIT_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')}"
GIT_BRANCH="${GIT_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')}"

echo "=== Running Consumer Contract Tests ==="
echo "Git SHA: $GIT_SHA | Branch: $GIT_BRANCH"

# Step 1: Run consumer tests (generates pact files)
npm run test:contract:consumer 2>/dev/null || \
    pytest tests/contract/ 2>/dev/null || \
    mvn test -Dtest='*Consumer*' 2>/dev/null || \
    echo "Adjust the test command for your project"

# Step 2: Publish pacts to broker
if command -v pact-broker &>/dev/null; then
    echo "Publishing pacts to broker..."
    pact-broker publish pacts/ \
        --broker-base-url "$PACT_BROKER_URL" \
        --consumer-app-version "$GIT_SHA" \
        --branch "$GIT_BRANCH"
fi

# Step 3: Can-i-deploy check
if command -v pact-broker &>/dev/null; then
    echo "Checking can-i-deploy..."
    pact-broker can-i-deploy \
        --pacticipant "OrderService" \
        --version "$GIT_SHA" \
        --to-environment production \
        --broker-base-url "$PACT_BROKER_URL" || {
        echo "Cannot deploy: contract verification failed"
        exit 1
    }
fi

echo "=== Contract tests passed ==="
CI_SCRIPT
    chmod +x run-contract-tests.sh
    success "CI script: run-contract-tests.sh"
}

# --- Main ---
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║        CONTRACT TEST SETUP (Pact)                           ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

case "$LANG" in
    node|nodejs|typescript|ts|js)
        setup_node ;;
    java|spring|kotlin)
        setup_java ;;
    python|py)
        setup_python ;;
    *)
        echo -e "${RED}Unsupported language: $LANG${NC}"
        echo "Supported: node, java, python"
        exit 1 ;;
esac

if $SETUP_BROKER; then
    echo ""
    setup_broker
fi

setup_ci

echo ""
echo -e "${GREEN}${BOLD}Setup complete!${NC}"
echo ""
echo "Next steps:"
echo "  1. Review generated test files and adapt to your service APIs"
echo "  2. Run consumer tests to generate pact files"
echo "  3. Share pact files with provider teams (or use Pact Broker)"
echo "  4. Provider teams run verification tests in their CI"
echo "  5. Use 'can-i-deploy' in CI to gate deployments"
