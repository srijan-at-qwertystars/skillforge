# Testing Strategies for Feature Flags

A comprehensive reference for engineers building robust, flag-aware test suites.
Feature flags add a combinatorial dimension to testing — every flag doubles the
number of possible code paths. This guide covers practical strategies to keep
coverage high without letting test counts explode.

---

## Table of Contents

1. [Unit Testing with Mock Providers](#1-unit-testing-with-mock-providers)
   - [TypeScript — Jest / Vitest](#typescript--jest--vitest)
   - [Python — pytest](#python--pytest)
   - [Go](#go)
   - [Java — JUnit 5](#java--junit-5)
   - [Per-Test Flag Overrides](#per-test-flag-overrides)
2. [Testing All Flag Combinations (Combinatorial Strategies)](#2-testing-all-flag-combinations-combinatorial-strategies)
   - [Why Full Combinatorial Testing Is Impractical](#why-full-combinatorial-testing-is-impractical)
   - [Pairwise (2-wise) Testing](#pairwise-2-wise-testing)
   - [N-wise Testing](#n-wise-testing)
   - [Generating Pairwise Matrices in Code](#generating-pairwise-matrices-in-code)
3. [Integration Testing with Flag States](#3-integration-testing-with-flag-states)
   - [Environment-Specific Flag Configurations](#environment-specific-flag-configurations)
   - [Testing Flag State Transitions](#testing-flag-state-transitions)
   - [Docker Compose with flagd](#docker-compose-with-flagd)
   - [Docker Compose with Unleash](#docker-compose-with-unleash)
4. [Testing Flag Evaluation Logic](#4-testing-flag-evaluation-logic)
   - [Testing Targeting Rules](#testing-targeting-rules)
   - [Percentage Rollout Verification](#percentage-rollout-verification)
   - [Deterministic Assignment](#deterministic-assignment)
   - [Edge Cases](#edge-cases)
5. [Contract Testing Between Flag Service and Consumers](#5-contract-testing-between-flag-service-and-consumers)
   - [Pact Contract Tests](#pact-contract-tests)
   - [Schema Validation for Flag Configs](#schema-validation-for-flag-configs)
   - [Flag Name and Type Compatibility](#flag-name-and-type-compatibility)
6. [Load Testing with Flag Changes](#6-load-testing-with-flag-changes)
   - [Benchmarking SDK Evaluation Latency](#benchmarking-sdk-evaluation-latency)
   - [Simulating Rollout Changes Under Load](#simulating-rollout-changes-under-load)
   - [Cache Behavior Under Concurrent Access](#cache-behavior-under-concurrent-access)
7. [Testing Rollback Scenarios](#7-testing-rollback-scenarios)
   - [Simulating Flag-Based Rollbacks](#simulating-flag-based-rollbacks)
   - [Chaos Testing with Random Flag Flips](#chaos-testing-with-random-flag-flips)
   - [Kill Switch Activation Paths](#kill-switch-activation-paths)
8. [Flag-Aware Test Fixtures](#8-flag-aware-test-fixtures)
   - [Test Factories That Respect Flag States](#test-factories-that-respect-flag-states)
   - [Dynamic Fixtures Based on Active Flags](#dynamic-fixtures-based-on-active-flags)
   - [Shared Test Utilities](#shared-test-utilities)
   - [CI Pipeline Integration](#ci-pipeline-integration)

---

## 1. Unit Testing with Mock Providers

The foundation of flag-aware testing is replacing the real flag provider with an
in-memory implementation you control completely. Every major SDK supports this.

### TypeScript — Jest / Vitest

**InMemoryProvider with the OpenFeature SDK:**

```typescript
// src/flags/provider.ts
import { OpenFeature, InMemoryProvider } from "@openfeature/server-sdk";

// Flag definitions for testing — keys map to default variants
const testFlags = {
  "checkout-v2": {
    variants: { on: true, off: false },
    defaultVariant: "off",
    disabled: false,
  },
  "search-algorithm": {
    variants: { legacy: "bm25", experimental: "vector" },
    defaultVariant: "legacy",
    disabled: false,
  },
};

export function setupTestProvider(overrides: Record<string, any> = {}) {
  const flags = { ...testFlags };

  // Apply per-test overrides
  for (const [key, value] of Object.entries(overrides)) {
    if (flags[key]) {
      const variantName = Object.entries(flags[key].variants).find(
        ([, v]) => v === value
      )?.[0];
      if (variantName) {
        flags[key] = { ...flags[key], defaultVariant: variantName };
      }
    }
  }

  const provider = new InMemoryProvider(flags);
  OpenFeature.setProvider(provider);
  return OpenFeature.getClient();
}
```

```typescript
// src/checkout/__tests__/checkout.test.ts
import { describe, it, expect, beforeEach } from "vitest";
import { setupTestProvider } from "../../flags/provider";
import { CheckoutService } from "../checkout-service";

describe("CheckoutService", () => {
  let client: ReturnType<typeof setupTestProvider>;

  describe("when checkout-v2 is OFF", () => {
    beforeEach(() => {
      client = setupTestProvider({ "checkout-v2": false });
    });

    it("uses the legacy checkout flow", async () => {
      const service = new CheckoutService(client);
      const result = await service.processOrder(mockOrder);
      expect(result.flow).toBe("legacy");
      expect(result.steps).toEqual(["validate", "charge", "fulfill"]);
    });
  });

  describe("when checkout-v2 is ON", () => {
    beforeEach(() => {
      client = setupTestProvider({ "checkout-v2": true });
    });

    it("uses the new checkout flow with fraud check", async () => {
      const service = new CheckoutService(client);
      const result = await service.processOrder(mockOrder);
      expect(result.flow).toBe("v2");
      expect(result.steps).toEqual([
        "validate",
        "fraud-check",
        "charge",
        "fulfill",
      ]);
    });
  });
});
```

**Custom mock provider for fine-grained control:**

```typescript
// test/helpers/mock-flag-provider.ts
import type { Provider, ResolutionDetails, EvaluationContext } from "@openfeature/server-sdk";

type FlagResolver = (context?: EvaluationContext) => any;

export class MockFlagProvider implements Provider {
  metadata = { name: "mock" };
  private values: Map<string, any | FlagResolver> = new Map();
  private evaluationLog: Array<{ flag: string; context?: EvaluationContext }> = [];

  set(flag: string, value: any | FlagResolver) {
    this.values.set(flag, value);
  }

  reset() {
    this.values.clear();
    this.evaluationLog = [];
  }

  getEvaluationLog() {
    return [...this.evaluationLog];
  }

  async resolveBooleanEvaluation(
    flagKey: string,
    defaultValue: boolean,
    context?: EvaluationContext
  ): Promise<ResolutionDetails<boolean>> {
    this.evaluationLog.push({ flag: flagKey, context });
    const stored = this.values.get(flagKey);
    const value = typeof stored === "function" ? stored(context) : stored;
    return { value: value ?? defaultValue, reason: "STATIC" };
  }

  // Implement resolveStringEvaluation, resolveNumberEvaluation,
  // resolveObjectEvaluation following the same pattern
}
```

### Python — pytest

```python
# tests/conftest.py
import pytest
from dataclasses import dataclass, field
from typing import Any, Callable, Optional


@dataclass
class MockFlagProvider:
    """In-memory flag provider for unit tests."""
    _flags: dict[str, Any] = field(default_factory=dict)
    _resolvers: dict[str, Callable] = field(default_factory=dict)
    _log: list[dict] = field(default_factory=list)

    def set_flag(self, key: str, value: Any) -> None:
        self._flags[key] = value

    def set_resolver(self, key: str, resolver: Callable) -> None:
        self._resolvers[key] = resolver

    def evaluate(self, key: str, default: Any = None,
                 context: Optional[dict] = None) -> Any:
        self._log.append({"flag": key, "context": context})

        if key in self._resolvers:
            return self._resolvers[key](context or {})
        return self._flags.get(key, default)

    def get_log(self) -> list[dict]:
        return list(self._log)

    def reset(self) -> None:
        self._flags.clear()
        self._resolvers.clear()
        self._log.clear()


@pytest.fixture
def flag_provider():
    provider = MockFlagProvider()
    yield provider
    provider.reset()


@pytest.fixture
def flags_all_on(flag_provider):
    """Convenience fixture: all known flags enabled."""
    for flag in ["checkout_v2", "dark_mode", "new_search", "beta_pricing"]:
        flag_provider.set_flag(flag, True)
    return flag_provider


@pytest.fixture
def flags_all_off(flag_provider):
    """Convenience fixture: all known flags disabled."""
    for flag in ["checkout_v2", "dark_mode", "new_search", "beta_pricing"]:
        flag_provider.set_flag(flag, False)
    return flag_provider
```

```python
# tests/test_search_service.py
import pytest
from services.search import SearchService


class TestSearchService:
    def test_legacy_search_when_flag_off(self, flag_provider):
        flag_provider.set_flag("new_search", False)
        service = SearchService(flag_provider)

        results = service.search("python testing")
        assert results.algorithm == "bm25"
        assert len(results.items) > 0

    def test_vector_search_when_flag_on(self, flag_provider):
        flag_provider.set_flag("new_search", True)
        service = SearchService(flag_provider)

        results = service.search("python testing")
        assert results.algorithm == "vector"
        assert hasattr(results, "similarity_scores")

    @pytest.mark.parametrize("flag_value,expected_algo", [
        (True, "vector"),
        (False, "bm25"),
    ])
    def test_search_algorithm_selection(self, flag_provider,
                                         flag_value, expected_algo):
        flag_provider.set_flag("new_search", flag_value)
        service = SearchService(flag_provider)
        assert service.search("query").algorithm == expected_algo
```

### Go

```go
// flags/testing.go
package flags

import (
	"sync"
)

// TestProvider is a thread-safe in-memory flag provider for tests.
type TestProvider struct {
	mu    sync.RWMutex
	flags map[string]interface{}
}

func NewTestProvider() *TestProvider {
	return &TestProvider{flags: make(map[string]interface{})}
}

func (p *TestProvider) Set(key string, value interface{}) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.flags[key] = value
}

func (p *TestProvider) GetBool(key string, defaultVal bool) bool {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if v, ok := p.flags[key]; ok {
		if b, ok := v.(bool); ok {
			return b
		}
	}
	return defaultVal
}

func (p *TestProvider) GetString(key string, defaultVal string) string {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if v, ok := p.flags[key]; ok {
		if s, ok := v.(string); ok {
			return s
		}
	}
	return defaultVal
}
```

```go
// checkout/checkout_test.go
package checkout

import (
	"testing"

	"myapp/flags"
)

func TestCheckout_LegacyFlow(t *testing.T) {
	fp := flags.NewTestProvider()
	fp.Set("checkout-v2", false)

	svc := NewService(fp)
	result, err := svc.Process(testOrder)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Flow != "legacy" {
		t.Errorf("expected legacy flow, got %s", result.Flow)
	}
}

func TestCheckout_V2Flow(t *testing.T) {
	fp := flags.NewTestProvider()
	fp.Set("checkout-v2", true)

	svc := NewService(fp)
	result, err := svc.Process(testOrder)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Flow != "v2" {
		t.Errorf("expected v2 flow, got %s", result.Flow)
	}
}

// Table-driven test for multiple flag combinations
func TestCheckout_Flows(t *testing.T) {
	cases := []struct {
		name     string
		flags    map[string]interface{}
		wantFlow string
	}{
		{"all off", map[string]interface{}{"checkout-v2": false, "fraud-check": false}, "legacy"},
		{"checkout v2 only", map[string]interface{}{"checkout-v2": true, "fraud-check": false}, "v2"},
		{"both on", map[string]interface{}{"checkout-v2": true, "fraud-check": true}, "v2-with-fraud"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			fp := flags.NewTestProvider()
			for k, v := range tc.flags {
				fp.Set(k, v)
			}
			svc := NewService(fp)
			result, _ := svc.Process(testOrder)
			if result.Flow != tc.wantFlow {
				t.Errorf("got flow %s, want %s", result.Flow, tc.wantFlow)
			}
		})
	}
}
```

### Java — JUnit 5

```java
// src/test/java/com/example/flags/InMemoryFlagProvider.java
package com.example.flags;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

public class InMemoryFlagProvider implements FlagProvider {
    private final Map<String, Object> flags = new ConcurrentHashMap<>();

    public void set(String key, Object value) {
        flags.put(key, value);
    }

    public void reset() {
        flags.clear();
    }

    @Override
    public boolean getBooleanValue(String key, boolean defaultValue) {
        Object v = flags.get(key);
        return v instanceof Boolean ? (Boolean) v : defaultValue;
    }

    @Override
    public String getStringValue(String key, String defaultValue) {
        Object v = flags.get(key);
        return v instanceof String ? (String) v : defaultValue;
    }
}
```

```java
// src/test/java/com/example/checkout/CheckoutServiceTest.java
package com.example.checkout;

import com.example.flags.InMemoryFlagProvider;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

import static org.assertj.core.api.Assertions.assertThat;

class CheckoutServiceTest {
    private InMemoryFlagProvider flags;
    private CheckoutService service;

    @BeforeEach
    void setUp() {
        flags = new InMemoryFlagProvider();
        service = new CheckoutService(flags);
    }

    @Nested
    class WhenCheckoutV2Disabled {
        @BeforeEach
        void setUp() { flags.set("checkout-v2", false); }

        @Test
        void usesLegacyFlow() {
            var result = service.processOrder(TestData.order());
            assertThat(result.getFlow()).isEqualTo("legacy");
        }
    }

    @ParameterizedTest
    @CsvSource({
        "true, v2",
        "false, legacy"
    })
    void selectsCorrectFlow(boolean flagValue, String expectedFlow) {
        flags.set("checkout-v2", flagValue);
        var result = service.processOrder(TestData.order());
        assertThat(result.getFlow()).isEqualTo(expectedFlow);
    }
}
```

### Per-Test Flag Overrides

A useful pattern is a helper that scopes flag values to a single test and
automatically restores defaults afterward:

```typescript
// test/helpers/with-flags.ts
type FlagOverrides = Record<string, boolean | string | number>;

export function withFlags(overrides: FlagOverrides) {
  return (testFn: () => Promise<void> | void) => {
    return async () => {
      const client = setupTestProvider(overrides);
      try {
        await testFn();
      } finally {
        // Provider resets happen in beforeEach, but this ensures
        // no leakage if a test throws.
        OpenFeature.clearProviders();
      }
    };
  };
}

// Usage:
it("shows new UI", withFlags({ "new-ui": true })(() => {
  render(<Dashboard />);
  expect(screen.getByTestId("new-dashboard")).toBeInTheDocument();
}));
```

---

## 2. Testing All Flag Combinations (Combinatorial Strategies)

### Why Full Combinatorial Testing Is Impractical

Each boolean flag doubles the state space:

| Flags | States  | At 1 ms/test | At 1 s/test    |
| ----- | ------- | ------------ | -------------- |
| 5     | 32      | 32 ms        | 32 s           |
| 10    | 1,024   | ~1 s         | ~17 min        |
| 15    | 32,768  | ~33 s        | ~9 hours       |
| 20    | 1M+     | ~17 min      | ~12 days       |

With multi-valued flags (e.g., 3 variants), growth is even faster.
Full exhaustive testing is unrealistic past ~8 boolean flags.

### Pairwise (2-wise) Testing

Pairwise testing covers every combination of values between **every pair of
flags**, rather than every combination overall. Research consistently shows that
most defects are caused by interactions between ≤2 parameters.

**Reduction example:**

- 10 boolean flags → 1,024 exhaustive combinations
- Pairwise: **~20 test cases** (covers all 2-way interactions)
- That is a **98% reduction** in test cases

**Tools:**

| Tool     | Platform    | Notes                              |
| -------- | ----------- | ---------------------------------- |
| PICT     | CLI (Win)   | Microsoft, widely used             |
| AllPairs | Perl script | James Bach's original tool         |
| pairwise | Python      | `pip install allpairspy`            |
| jenny    | C           | Open source, fast                  |

### N-wise Testing

When 2-way coverage is not enough, increase to 3-wise or higher:

- **2-wise (pairwise):** Catches interactions between any 2 flags.
  Covers ~90% of real-world interaction bugs.
- **3-wise:** Catches 3-flag interactions. Cases grow but remain tractable.
- **4-wise+:** Rarely needed. Consider targeted scenario tests instead.

### Generating Pairwise Matrices in Code

**Python with `allpairspy`:**

```python
# tests/generate_flag_matrix.py
from allpairspy import AllPairs
import json

# Define all flags and their possible values
flag_parameters = [
    # (flag_name, possible_values)
    ("checkout_v2",     [True, False]),
    ("dark_mode",       [True, False]),
    ("new_search",      [True, False]),
    ("beta_pricing",    [True, False]),
    ("fraud_check",     [True, False]),
    ("new_onboarding",  [True, False]),
    ("experiment_ui",   ["control", "variant_a", "variant_b"]),
    ("cache_strategy",  ["redis", "memcached", "local"]),
    ("log_level",       ["debug", "info", "warn"]),
    ("api_version",     ["v1", "v2"]),
]

flag_names = [name for name, _ in flag_parameters]
flag_values = [values for _, values in flag_parameters]

# Generate pairwise combinations
pairs = list(AllPairs(flag_values))

print(f"Exhaustive combinations: {eval('*'.join(str(len(v)) for v in flag_values)):,}")
print(f"Pairwise combinations:   {len(pairs)}")
print(f"Reduction:               {100 - len(pairs) / eval('*'.join(str(len(v)) for v in flag_values)) * 100:.1f}%")

# Convert to list of dicts for easy consumption in tests
test_matrix = []
for combo in pairs:
    test_case = dict(zip(flag_names, combo))
    test_matrix.append(test_case)

# Write to JSON for test runners to consume
with open("tests/flag_matrix.json", "w") as f:
    json.dump(test_matrix, f, indent=2)
```

**Using the matrix in pytest:**

```python
# tests/test_flag_combinations.py
import json
import pytest
from pathlib import Path

matrix_path = Path(__file__).parent / "flag_matrix.json"
FLAG_MATRIX = json.loads(matrix_path.read_text())


@pytest.mark.parametrize(
    "flag_combo",
    FLAG_MATRIX,
    ids=[f"combo-{i}" for i in range(len(FLAG_MATRIX))],
)
def test_app_boots_with_flag_combination(flag_combo, flag_provider):
    """Verify the app initializes without error for each pairwise combo."""
    for flag, value in flag_combo.items():
        flag_provider.set_flag(flag, value)

    app = create_app(flag_provider)
    assert app.health_check() == "ok"
```

**TypeScript — generating and consuming the matrix:**

```typescript
// scripts/generate-flag-matrix.ts
import { allPairs } from "allpairspy"; // or use a JS pairwise lib

const flagDefs = {
  "checkout-v2": [true, false],
  "dark-mode": [true, false],
  "new-search": [true, false],
  "experiment-ui": ["control", "variant_a", "variant_b"],
  "api-version": ["v1", "v2"],
};

const names = Object.keys(flagDefs);
const values = Object.values(flagDefs);

// allPairs returns arrays — zip with names for readable output
const matrix = allPairs(values).map((combo) =>
  Object.fromEntries(names.map((name, i) => [name, combo[i]]))
);

console.log(`Generated ${matrix.length} pairwise test cases`);
Bun.write("test/flag-matrix.json", JSON.stringify(matrix, null, 2));
```

```typescript
// test/flag-combinations.test.ts
import matrix from "./flag-matrix.json";

describe.each(matrix)("flag combination $#", (combo) => {
  it("renders without crashing", () => {
    const client = setupTestProvider(combo);
    const app = createApp(client);
    expect(app.status()).toBe("healthy");
  });
});
```

---

## 3. Integration Testing with Flag States

Unit tests with mocks prove code paths work in isolation. Integration tests
verify that **real flag infrastructure** behaves correctly.

### Environment-Specific Flag Configurations

```yaml
# config/flags/staging.yaml
flags:
  checkout-v2:
    state: ENABLED
    variants:
      "on": true
      "off": false
    defaultVariant: "on"
    targeting:
      # Enable for staging test users only
      if:
        - in:
            - var: email
            - ["staging-qa@example.com", "load-test@example.com"]
        - "on"
        - "off"

  new-search:
    state: ENABLED
    defaultVariant: "off"  # default off even in staging
```

### Testing Flag State Transitions

```python
# tests/integration/test_flag_transitions.py
import pytest
import httpx
import time


class TestFlagTransitions:
    """
    Integration tests that verify behavior as flags change state.
    Requires a running flag service (flagd, LaunchDarkly, etc).
    """

    @pytest.fixture(autouse=True)
    def flag_api(self):
        self.client = httpx.Client(base_url="http://localhost:8080")
        self.flag_service = httpx.Client(
            base_url="http://localhost:8013",  # flagd admin API
        )
        yield
        self.client.close()
        self.flag_service.close()

    def set_flag(self, key: str, enabled: bool):
        """Toggle a flag via the admin API and wait for propagation."""
        self.flag_service.put(f"/flags/{key}", json={"enabled": enabled})
        time.sleep(0.5)  # allow SDK polling interval to pick up change

    def test_transition_from_legacy_to_v2(self):
        # Start with legacy
        self.set_flag("checkout-v2", False)
        resp = self.client.post("/checkout", json={"item": "widget"})
        assert resp.json()["flow"] == "legacy"

        # Flip the flag
        self.set_flag("checkout-v2", True)
        resp = self.client.post("/checkout", json={"item": "widget"})
        assert resp.json()["flow"] == "v2"

    def test_in_flight_requests_during_flag_change(self):
        """Requests in progress when a flag changes should complete
        using the flag value they started with."""
        self.set_flag("checkout-v2", False)

        # Start a slow request (backend has artificial delay in staging)
        import concurrent.futures
        with concurrent.futures.ThreadPoolExecutor() as pool:
            future = pool.submit(
                self.client.post,
                "/checkout",
                json={"item": "widget", "simulate_delay_ms": 2000},
            )
            time.sleep(0.2)
            # Flip while request is in flight
            self.set_flag("checkout-v2", True)

            result = future.result()
            # The in-flight request should have used the OLD value
            assert result.json()["flow"] == "legacy"
```

### Docker Compose with flagd

```yaml
# docker-compose.test.yml
version: "3.8"

services:
  flagd:
    image: ghcr.io/open-feature/flagd:latest
    ports:
      - "8013:8013"
    volumes:
      - ./config/flags/test.flagd.json:/flags.json
    command: start --uri file:/flags.json

  app:
    build:
      context: .
      dockerfile: Dockerfile
    environment:
      FLAG_PROVIDER: flagd
      FLAG_HOST: flagd
      FLAG_PORT: 8013
    depends_on:
      flagd:
        condition: service_started
    ports:
      - "8080:8080"

  integration-tests:
    build:
      context: .
      dockerfile: Dockerfile.test
    environment:
      APP_URL: http://app:8080
      FLAGD_URL: http://flagd:8013
    depends_on:
      - app
    command: pytest tests/integration/ -v --tb=short
```

```json
// config/flags/test.flagd.json
{
  "$schema": "https://flagd.dev/schema/v0/flags.json",
  "flags": {
    "checkout-v2": {
      "state": "ENABLED",
      "variants": { "on": true, "off": false },
      "defaultVariant": "off"
    },
    "new-search": {
      "state": "ENABLED",
      "variants": {
        "legacy": "bm25",
        "experimental": "vector"
      },
      "defaultVariant": "legacy"
    }
  }
}
```

### Docker Compose with Unleash

```yaml
# docker-compose.unleash.yml
version: "3.8"

services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_DB: unleash
      POSTGRES_USER: unleash
      POSTGRES_PASSWORD: unleash
    tmpfs:
      - /var/lib/postgresql/data

  unleash:
    image: unleashorg/unleash-server:latest
    environment:
      DATABASE_URL: postgres://unleash:unleash@postgres:5432/unleash
      DATABASE_SSL: "false"
    depends_on:
      - postgres
    ports:
      - "4242:4242"
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:4242/health"]
      interval: 5s
      retries: 20

  setup-flags:
    image: curlimages/curl:latest
    depends_on:
      unleash:
        condition: service_healthy
    entrypoint: /bin/sh
    command:
      - -c
      - |
        # Create project and flags via Unleash API
        curl -s -X POST http://unleash:4242/api/admin/features \
          -H "Authorization: *:*.unleash-insecure-api-token" \
          -H "Content-Type: application/json" \
          -d '{"name":"checkout-v2","type":"release","enabled":false}'

  app:
    build: .
    environment:
      UNLEASH_URL: http://unleash:4242/api
      UNLEASH_API_TOKEN: "*:*.unleash-insecure-api-token"
    depends_on:
      setup-flags:
        condition: service_completed_successfully
    ports:
      - "8080:8080"
```

---

## 4. Testing Flag Evaluation Logic

### Testing Targeting Rules

```typescript
// test/targeting-rules.test.ts
import { describe, it, expect } from "vitest";
import { evaluateFlag, type TargetingRule } from "../src/flags/evaluator";

const betaUsersRule: TargetingRule = {
  flag: "new-dashboard",
  rules: [
    {
      // Enable for beta users
      condition: { attribute: "userTier", operator: "in", values: ["beta", "internal"] },
      variant: "on",
    },
    {
      // Enable for specific org
      condition: { attribute: "orgId", operator: "equals", value: "org-42" },
      variant: "on",
    },
  ],
  defaultVariant: "off",
};

describe("Targeting rules", () => {
  it("enables for beta-tier users", () => {
    const result = evaluateFlag(betaUsersRule, { userTier: "beta", userId: "u1" });
    expect(result).toBe(true);
  });

  it("enables for the target org", () => {
    const result = evaluateFlag(betaUsersRule, { orgId: "org-42", userId: "u2" });
    expect(result).toBe(true);
  });

  it("disables for non-matching users", () => {
    const result = evaluateFlag(betaUsersRule, { userTier: "free", orgId: "org-99" });
    expect(result).toBe(false);
  });

  it("disables when required attributes are missing", () => {
    const result = evaluateFlag(betaUsersRule, { userId: "u3" });
    expect(result).toBe(false);
  });
});
```

### Percentage Rollout Verification

```python
# tests/test_percentage_rollout.py
import pytest
from collections import Counter
from flags.evaluator import evaluate_percentage_rollout


class TestPercentageRollout:
    """Verify that percentage-based rollouts produce statistically
    correct distributions."""

    def test_50_percent_rollout_distribution(self):
        results = Counter()
        num_users = 10_000

        for i in range(num_users):
            user_id = f"user-{i}"
            result = evaluate_percentage_rollout(
                flag="gradual-feature",
                user_id=user_id,
                percentage=50,
            )
            results[result] += 1

        enabled_pct = results[True] / num_users * 100
        # Allow ±3% tolerance for statistical variance
        assert 47 <= enabled_pct <= 53, (
            f"Expected ~50% enabled, got {enabled_pct:.1f}%"
        )

    def test_0_percent_rollout_enables_nobody(self):
        for i in range(1000):
            result = evaluate_percentage_rollout(
                flag="disabled-feature", user_id=f"user-{i}", percentage=0
            )
            assert result is False

    def test_100_percent_rollout_enables_everyone(self):
        for i in range(1000):
            result = evaluate_percentage_rollout(
                flag="fully-rolled-out", user_id=f"user-{i}", percentage=100
            )
            assert result is True

    @pytest.mark.parametrize("percentage", [10, 25, 50, 75, 90])
    def test_rollout_percentage_within_tolerance(self, percentage):
        results = [
            evaluate_percentage_rollout(
                flag="test-flag", user_id=f"u-{i}", percentage=percentage
            )
            for i in range(10_000)
        ]
        actual_pct = sum(results) / len(results) * 100
        assert abs(actual_pct - percentage) < 5, (
            f"{percentage}% rollout produced {actual_pct:.1f}%"
        )
```

### Deterministic Assignment

The same user must always get the same flag value for a given flag and rollout
percentage. This is critical for consistent user experience.

```typescript
// test/deterministic-assignment.test.ts
describe("Deterministic assignment", () => {
  it("same user always gets the same variant", () => {
    const userId = "user-abc-123";
    const flag = "experiment-checkout";
    const percentage = 50;

    const results = new Set<boolean>();
    for (let i = 0; i < 100; i++) {
      results.add(evaluatePercentageRollout(flag, userId, percentage));
    }

    // Should only ever produce ONE value for the same user
    expect(results.size).toBe(1);
  });

  it("different users can get different variants", () => {
    const results = new Set<boolean>();
    for (let i = 0; i < 100; i++) {
      results.add(
        evaluatePercentageRollout("experiment", `user-${i}`, 50)
      );
    }
    // With 100 users at 50%, we should see both true and false
    expect(results.size).toBe(2);
  });

  it("assignment is stable across flag evaluator restarts", () => {
    const userId = "stable-user-789";
    const first = evaluatePercentageRollout("my-flag", userId, 30);

    // Simulate restart by creating a new evaluator instance
    const freshEvaluator = new FlagEvaluator();
    const second = freshEvaluator.evaluatePercentageRollout("my-flag", userId, 30);

    expect(second).toBe(first);
  });
});
```

### Edge Cases

```python
# tests/test_flag_edge_cases.py
import pytest
from flags.evaluator import FlagEvaluator


class TestFlagEdgeCases:
    def setup_method(self):
        self.evaluator = FlagEvaluator()

    def test_unknown_flag_returns_default(self):
        result = self.evaluator.evaluate(
            "nonexistent-flag", default=False, context={}
        )
        assert result is False

    def test_null_context_does_not_crash(self):
        result = self.evaluator.evaluate(
            "checkout-v2", default=False, context=None
        )
        assert isinstance(result, bool)

    def test_empty_context_uses_default_variant(self):
        result = self.evaluator.evaluate(
            "targeted-feature", default=False, context={}
        )
        assert result is False  # no targeting attributes → default

    def test_missing_user_id_in_percentage_rollout(self):
        """Percentage rollout requires a user ID for hashing.
        Missing ID should fall back to default, not raise."""
        result = self.evaluator.evaluate(
            "gradual-feature",
            default=False,
            context={"orgId": "org-1"},  # no userId
        )
        assert result is False

    def test_flag_with_empty_string_key(self):
        with pytest.raises(ValueError, match="Flag key must not be empty"):
            self.evaluator.evaluate("", default=False, context={})

    def test_context_with_unexpected_types(self):
        """Context values should be coerced or ignored, never crash."""
        weird_context = {
            "userId": 12345,       # int instead of str
            "plan": None,          # null
            "tags": ["a", "b"],    # list
        }
        result = self.evaluator.evaluate(
            "checkout-v2", default=False, context=weird_context
        )
        assert isinstance(result, bool)
```

---

## 5. Contract Testing Between Flag Service and Consumers

### Pact Contract Tests

Use contract testing to ensure that the flag service API and the consuming
application agree on flag names, types, and structures.

```typescript
// test/contracts/flag-consumer.pact.test.ts
import { PactV3, MatchersV3 } from "@pact-foundation/pact";
import { FlagClient } from "../../src/flags/client";

const { boolean, string, eachLike } = MatchersV3;

const provider = new PactV3({
  consumer: "CheckoutService",
  provider: "FlagService",
  dir: "./pacts",
});

describe("Flag Service Contract", () => {
  it("returns boolean flag values", async () => {
    await provider
      .given("flag checkout-v2 exists")
      .uponReceiving("a request for boolean flag checkout-v2")
      .withRequest({
        method: "POST",
        path: "/flags/evaluate",
        headers: { "Content-Type": "application/json" },
        body: {
          flagKey: "checkout-v2",
          context: { userId: string("user-123") },
        },
      })
      .willRespondWith({
        status: 200,
        headers: { "Content-Type": "application/json" },
        body: {
          key: string("checkout-v2"),
          value: boolean(true),
          variant: string("on"),
          reason: string("TARGETING_MATCH"),
        },
      })
      .executeTest(async (mockServer) => {
        const client = new FlagClient(mockServer.url);
        const result = await client.evaluateBoolean("checkout-v2", {
          userId: "user-123",
        });

        expect(result.value).toBe(true);
        expect(result.variant).toBe("on");
      });
  });

  it("returns a default when flag does not exist", async () => {
    await provider
      .given("flag unknown-flag does NOT exist")
      .uponReceiving("a request for nonexistent flag")
      .withRequest({
        method: "POST",
        path: "/flags/evaluate",
        body: { flagKey: "unknown-flag", context: {} },
      })
      .willRespondWith({
        status: 200,
        body: {
          key: string("unknown-flag"),
          value: boolean(false),
          reason: string("DEFAULT"),
        },
      })
      .executeTest(async (mockServer) => {
        const client = new FlagClient(mockServer.url);
        const result = await client.evaluateBoolean("unknown-flag", {});
        expect(result.value).toBe(false);
        expect(result.reason).toBe("DEFAULT");
      });
  });
});
```

### Schema Validation for Flag Configs

```python
# tests/test_flag_schema.py
import json
import jsonschema
import pytest
from pathlib import Path

FLAG_CONFIG_SCHEMA = {
    "type": "object",
    "properties": {
        "flags": {
            "type": "object",
            "additionalProperties": {
                "type": "object",
                "required": ["state", "variants", "defaultVariant"],
                "properties": {
                    "state": {"enum": ["ENABLED", "DISABLED"]},
                    "variants": {
                        "type": "object",
                        "minProperties": 1,
                    },
                    "defaultVariant": {"type": "string"},
                    "targeting": {"type": "object"},
                },
                "additionalProperties": False,
            },
        }
    },
    "required": ["flags"],
}


class TestFlagConfigSchema:
    @pytest.fixture(params=list(
        Path("config/flags").glob("*.json")
    ))
    def flag_config(self, request):
        return json.loads(request.param.read_text())

    def test_config_matches_schema(self, flag_config):
        jsonschema.validate(flag_config, FLAG_CONFIG_SCHEMA)

    def test_default_variant_exists_in_variants(self, flag_config):
        for name, flag in flag_config["flags"].items():
            assert flag["defaultVariant"] in flag["variants"], (
                f"Flag '{name}' defaultVariant '{flag['defaultVariant']}' "
                f"not found in variants: {list(flag['variants'].keys())}"
            )

    def test_no_duplicate_flag_keys_across_files(self):
        all_keys: dict[str, str] = {}
        for path in Path("config/flags").glob("*.json"):
            config = json.loads(path.read_text())
            for key in config.get("flags", {}):
                if key in all_keys:
                    pytest.fail(
                        f"Duplicate flag '{key}' in {path} "
                        f"and {all_keys[key]}"
                    )
                all_keys[key] = str(path)
```

### Flag Name and Type Compatibility

```typescript
// test/flag-compatibility.test.ts
import { describe, it, expect } from "vitest";
import * as fs from "fs";

// The "source of truth" flag manifest from the flag service
const flagManifest = JSON.parse(
  fs.readFileSync("config/flag-manifest.json", "utf-8")
);

// Every flag key referenced in application code (extracted at build time
// by a custom eslint rule or a simple grep script)
const consumedFlags = JSON.parse(
  fs.readFileSync("build/consumed-flags.json", "utf-8")
);

describe("Flag compatibility", () => {
  it("all consumed flags exist in the manifest", () => {
    const missing = consumedFlags.filter(
      (f: string) => !(f in flagManifest.flags)
    );
    expect(missing).toEqual([]);
  });

  it("all consumed boolean flags are typed as boolean in the manifest", () => {
    for (const flag of consumedFlags) {
      const def = flagManifest.flags[flag];
      if (!def) continue;

      const variants = Object.values(def.variants);
      const isBooleanFlag = variants.every(
        (v: unknown) => typeof v === "boolean"
      );
      // If the code calls getBooleanValue, the manifest must define boolean variants
      expect(isBooleanFlag).toBe(true);
    }
  });

  it("no flags in the manifest are completely unused", () => {
    const unused = Object.keys(flagManifest.flags).filter(
      (f) => !consumedFlags.includes(f)
    );
    // Warning, not a hard fail — unused flags may be consumed by other services
    if (unused.length > 0) {
      console.warn(`Potentially unused flags: ${unused.join(", ")}`);
    }
  });
});
```

---

## 6. Load Testing with Flag Changes

### Benchmarking SDK Evaluation Latency

```typescript
// bench/flag-evaluation.bench.ts
import { bench, describe } from "vitest";
import { InMemoryProvider, OpenFeature } from "@openfeature/server-sdk";

const provider = new InMemoryProvider({
  "checkout-v2": {
    variants: { on: true, off: false },
    defaultVariant: "off",
    disabled: false,
  },
});
OpenFeature.setProvider(provider);
const client = OpenFeature.getClient();

describe("Flag evaluation latency", () => {
  bench("boolean flag evaluation", async () => {
    await client.getBooleanValue("checkout-v2", false);
  });

  bench("boolean flag with context", async () => {
    await client.getBooleanValue("checkout-v2", false, {
      targetingKey: "user-42",
      email: "test@example.com",
    });
  });

  bench("1000 sequential evaluations", async () => {
    for (let i = 0; i < 1000; i++) {
      await client.getBooleanValue("checkout-v2", false, {
        targetingKey: `user-${i}`,
      });
    }
  });
});
```

```python
# bench/benchmark_flags.py
"""
Run: python -m pytest bench/benchmark_flags.py --benchmark-only
Requires: pip install pytest-benchmark
"""
import pytest
from flags.evaluator import FlagEvaluator


@pytest.fixture(scope="module")
def evaluator():
    ev = FlagEvaluator()
    ev.load_config("config/flags/production.json")
    return ev


def test_simple_boolean_eval(benchmark, evaluator):
    benchmark(
        evaluator.evaluate,
        "checkout-v2",
        default=False,
        context={"userId": "bench-user"},
    )


def test_targeted_eval_with_rules(benchmark, evaluator):
    benchmark(
        evaluator.evaluate,
        "beta-feature",
        default=False,
        context={
            "userId": "bench-user",
            "orgId": "org-42",
            "plan": "enterprise",
            "region": "us-east-1",
        },
    )


def test_percentage_rollout_eval(benchmark, evaluator):
    benchmark(
        evaluator.evaluate_percentage_rollout,
        flag="gradual-feature",
        user_id="bench-user",
        percentage=50,
    )
```

### Simulating Rollout Changes Under Load

```python
# tests/load/test_flag_change_under_load.py
"""
Simulate flag changes while the system is under load.
Uses locust-style approach but in a self-contained test.
"""
import threading
import time
import httpx
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field


@dataclass
class LoadTestResult:
    total_requests: int = 0
    errors: int = 0
    latencies_ms: list[float] = field(default_factory=list)
    flag_values_seen: list[bool] = field(default_factory=list)

    @property
    def p50(self) -> float:
        s = sorted(self.latencies_ms)
        return s[len(s) // 2] if s else 0

    @property
    def p99(self) -> float:
        s = sorted(self.latencies_ms)
        idx = int(len(s) * 0.99)
        return s[idx] if s else 0


def run_flag_change_under_load(
    app_url: str,
    flagd_url: str,
    duration_seconds: int = 30,
    concurrency: int = 10,
    change_flag_at_second: int = 15,
):
    result = LoadTestResult()
    stop = threading.Event()

    def make_requests():
        client = httpx.Client(base_url=app_url, timeout=5.0)
        while not stop.is_set():
            start = time.monotonic()
            try:
                resp = client.post("/checkout", json={"item": "widget"})
                elapsed = (time.monotonic() - start) * 1000
                result.latencies_ms.append(elapsed)
                result.total_requests += 1
                result.flag_values_seen.append(resp.json().get("v2", False))
            except Exception:
                result.errors += 1
        client.close()

    def flip_flag():
        time.sleep(change_flag_at_second)
        httpx.put(
            f"{flagd_url}/flags/checkout-v2",
            json={"enabled": True},
        )

    # Run load + flag change concurrently
    with ThreadPoolExecutor(max_workers=concurrency + 1) as pool:
        futures = [pool.submit(make_requests) for _ in range(concurrency)]
        futures.append(pool.submit(flip_flag))

        time.sleep(duration_seconds)
        stop.set()

    print(f"Total requests: {result.total_requests}")
    print(f"Errors: {result.errors}")
    print(f"p50 latency: {result.p50:.1f}ms")
    print(f"p99 latency: {result.p99:.1f}ms")

    # Verify: both True and False should appear (flag changed mid-test)
    assert True in result.flag_values_seen, "Flag should have been enabled"
    assert False in result.flag_values_seen, "Flag should have started disabled"

    return result
```

### Cache Behavior Under Concurrent Access

```typescript
// test/cache-concurrency.test.ts
import { describe, it, expect } from "vitest";
import { CachedFlagProvider } from "../src/flags/cached-provider";

describe("Flag cache under concurrent access", () => {
  it("returns consistent values during cache refresh", async () => {
    const provider = new CachedFlagProvider({
      source: mockRemoteProvider,
      ttlMs: 100, // short TTL to trigger frequent refreshes
    });

    // Hammer the cache from multiple "threads"
    const results = await Promise.all(
      Array.from({ length: 100 }, (_, i) =>
        provider.getBooleanValue("checkout-v2", false, {
          targetingKey: `user-${i}`,
        })
      )
    );

    // All evaluations should succeed (no undefined, no errors)
    expect(results.every((r) => typeof r === "boolean")).toBe(true);
  });

  it("does not serve stale values after source changes", async () => {
    const source = new MockRemoteProvider();
    source.set("feature-x", false);

    const provider = new CachedFlagProvider({ source, ttlMs: 50 });

    const before = await provider.getBooleanValue("feature-x", false);
    expect(before).toBe(false);

    source.set("feature-x", true);

    // Wait for cache TTL to expire
    await new Promise((r) => setTimeout(r, 100));

    const after = await provider.getBooleanValue("feature-x", false);
    expect(after).toBe(true);
  });
});
```

---

## 7. Testing Rollback Scenarios

### Simulating Flag-Based Rollbacks

```typescript
// test/rollback.test.ts
import { describe, it, expect, beforeEach } from "vitest";

describe("Flag-based rollback", () => {
  let flagProvider: MockFlagProvider;
  let app: TestApp;

  beforeEach(() => {
    flagProvider = new MockFlagProvider();
    app = createTestApp(flagProvider);
  });

  it("reverts to legacy behavior when flag is turned off", async () => {
    // 1. Start with new behavior
    flagProvider.set("checkout-v2", true);
    const v2Result = await app.checkout(testOrder);
    expect(v2Result.flow).toBe("v2");

    // 2. Simulate rollback
    flagProvider.set("checkout-v2", false);
    const rollbackResult = await app.checkout(testOrder);
    expect(rollbackResult.flow).toBe("legacy");

    // 3. Verify data integrity — orders placed during v2 are still valid
    const order = await app.getOrder(v2Result.orderId);
    expect(order.status).toBe("completed");
  });

  it("handles rollback during active user sessions", async () => {
    flagProvider.set("new-dashboard", true);

    // Simulate a user session with cached flag value
    const session = await app.createSession("user-1");
    expect(session.dashboard).toBe("v2");

    // Rollback the flag
    flagProvider.set("new-dashboard", false);

    // New page loads should get the rolled-back value
    const freshLoad = await app.loadDashboard("user-1");
    expect(freshLoad.dashboard).toBe("legacy");
  });
});
```

### Chaos Testing with Random Flag Flips

```python
# tests/chaos/test_random_flag_flips.py
"""
Chaos test: randomly flip flags and verify the system stays healthy.
Run with: pytest tests/chaos/ -v --timeout=120
"""
import random
import time
import threading
import httpx
import pytest


ALL_FLAGS = [
    "checkout-v2",
    "new-search",
    "dark-mode",
    "beta-pricing",
    "new-onboarding",
]


class FlagFlipper:
    """Randomly toggles flags at irregular intervals."""

    def __init__(self, flagd_url: str, flags: list[str]):
        self.flagd_url = flagd_url
        self.flags = flags
        self.stop_event = threading.Event()
        self.flip_log: list[dict] = []

    def start(self):
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        self.thread.join(timeout=5)

    def _run(self):
        client = httpx.Client(base_url=self.flagd_url)
        while not self.stop_event.is_set():
            flag = random.choice(self.flags)
            value = random.choice([True, False])
            try:
                client.put(f"/flags/{flag}", json={"enabled": value})
                self.flip_log.append({
                    "flag": flag,
                    "value": value,
                    "time": time.time(),
                })
            except Exception:
                pass
            time.sleep(random.uniform(0.1, 2.0))
        client.close()


@pytest.fixture
def flag_flipper():
    flipper = FlagFlipper("http://localhost:8013", ALL_FLAGS)
    flipper.start()
    yield flipper
    flipper.stop()


class TestChaosFlags:
    def test_system_stays_healthy_during_random_flips(
        self, flag_flipper
    ):
        """The app should respond 200 regardless of flag state."""
        client = httpx.Client(base_url="http://localhost:8080")
        errors = []

        for _ in range(200):
            try:
                resp = client.get("/health")
                if resp.status_code != 200:
                    errors.append(f"Status {resp.status_code}")
            except Exception as e:
                errors.append(str(e))
            time.sleep(0.1)

        client.close()

        assert len(errors) == 0, (
            f"{len(errors)} errors during chaos test: {errors[:5]}"
        )
        assert len(flag_flipper.flip_log) > 10, (
            "Flipper should have toggled flags during the test"
        )

    def test_no_500_errors_during_rapid_flips(self, flag_flipper):
        """Rapid flag changes should never cause internal server errors."""
        client = httpx.Client(base_url="http://localhost:8080")
        status_codes = []

        for i in range(100):
            resp = client.post(
                "/checkout",
                json={"item": f"widget-{i}"},
            )
            status_codes.append(resp.status_code)

        client.close()
        assert 500 not in status_codes
```

### Kill Switch Activation Paths

```typescript
// test/kill-switch.test.ts
import { describe, it, expect, vi, beforeEach } from "vitest";

describe("Kill switch activation", () => {
  let flagProvider: MockFlagProvider;
  let app: TestApp;
  let alertSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    flagProvider = new MockFlagProvider();
    alertSpy = vi.fn();
    app = createTestApp(flagProvider, { onAlert: alertSpy });
  });

  it("immediately disables the feature when kill switch is activated", async () => {
    // Feature is live
    flagProvider.set("payments-enabled", true);
    const r1 = await app.processPayment({ amount: 100 });
    expect(r1.status).toBe("processed");

    // Activate kill switch
    flagProvider.set("payments-enabled", false);

    // Next request should be rejected gracefully
    const r2 = await app.processPayment({ amount: 200 });
    expect(r2.status).toBe("temporarily_unavailable");
    expect(r2.message).toContain("try again later");
  });

  it("triggers an alert when kill switch fires", async () => {
    flagProvider.set("payments-enabled", true);
    flagProvider.set("payments-enabled", false);

    // The app should detect the change and fire an alert
    await app.processPayment({ amount: 100 });
    expect(alertSpy).toHaveBeenCalledWith(
      expect.objectContaining({
        type: "kill_switch_activated",
        flag: "payments-enabled",
      })
    );
  });

  it("resumes normal operation when kill switch is deactivated", async () => {
    flagProvider.set("payments-enabled", true);
    flagProvider.set("payments-enabled", false);

    const r1 = await app.processPayment({ amount: 100 });
    expect(r1.status).toBe("temporarily_unavailable");

    // Restore
    flagProvider.set("payments-enabled", true);
    const r2 = await app.processPayment({ amount: 100 });
    expect(r2.status).toBe("processed");
  });

  it("queued work completes even after kill switch", async () => {
    flagProvider.set("batch-processing", true);

    // Enqueue work
    const jobId = await app.enqueueJob({ type: "report", size: "large" });

    // Kill switch mid-processing
    flagProvider.set("batch-processing", false);

    // Already-started job should finish; new jobs are rejected
    const job = await app.waitForJob(jobId);
    expect(job.status).toBe("completed");

    const newJob = await app.enqueueJob({ type: "report", size: "small" });
    expect(newJob.status).toBe("rejected");
  });
});
```

---

## 8. Flag-Aware Test Fixtures

### Test Factories That Respect Flag States

```typescript
// test/factories/order-factory.ts
import { faker } from "@faker-js/faker";
import type { FlagProvider } from "../../src/flags/types";

interface OrderFactoryOptions {
  overrides?: Partial<Order>;
}

export function createOrderFactory(flagProvider: FlagProvider) {
  return async function buildOrder(
    opts: OrderFactoryOptions = {}
  ): Promise<Order> {
    const useV2Checkout = await flagProvider.getBooleanValue(
      "checkout-v2",
      false
    );

    const baseOrder: Order = {
      id: faker.string.uuid(),
      items: [
        {
          sku: faker.commerce.isbn(),
          quantity: faker.number.int({ min: 1, max: 5 }),
          price: parseFloat(faker.commerce.price()),
        },
      ],
      customer: {
        id: faker.string.uuid(),
        email: faker.internet.email(),
      },
      // V2 checkout has additional fields
      ...(useV2Checkout && {
        fraudScore: faker.number.float({ min: 0, max: 1 }),
        riskLevel: "low" as const,
        paymentMethod: { type: "card", tokenized: true },
      }),
      ...opts.overrides,
    };

    return baseOrder;
  };
}

// Usage in tests:
// const buildOrder = createOrderFactory(flagProvider);
// const order = await buildOrder();
```

### Dynamic Fixtures Based on Active Flags

```python
# tests/factories.py
import uuid
from dataclasses import dataclass, field
from typing import Any

from faker import Faker

fake = Faker()


@dataclass
class DynamicFixtureFactory:
    """Generates test data shaped by the current flag configuration."""

    flag_provider: Any

    def build_user(self, **overrides) -> dict:
        base = {
            "id": str(uuid.uuid4()),
            "email": fake.email(),
            "name": fake.name(),
        }

        if self.flag_provider.evaluate("new_onboarding", default=False):
            base["onboarding_step"] = 1
            base["onboarding_completed"] = False
            base["preferences"] = {"theme": "system", "notifications": True}

        if self.flag_provider.evaluate("beta_pricing", default=False):
            base["pricing_tier"] = "beta_v2"
            base["discount_eligible"] = True

        base.update(overrides)
        return base

    def build_order(self, user: dict = None, **overrides) -> dict:
        user = user or self.build_user()
        base = {
            "id": str(uuid.uuid4()),
            "user_id": user["id"],
            "items": [
                {"sku": fake.ean13(), "qty": fake.random_int(1, 5)}
            ],
            "total": float(fake.pydecimal(left_digits=3, right_digits=2,
                                          positive=True)),
        }

        if self.flag_provider.evaluate("checkout_v2", default=False):
            base["fraud_score"] = fake.pyfloat(min_value=0, max_value=1)
            base["payment_token"] = fake.sha256()

        base.update(overrides)
        return base
```

```python
# tests/conftest.py (continued)
@pytest.fixture
def factory(flag_provider):
    return DynamicFixtureFactory(flag_provider)


# Usage:
# def test_order_processing(factory, flag_provider):
#     flag_provider.set_flag("checkout_v2", True)
#     order = factory.build_order()
#     assert "fraud_score" in order
```

### Shared Test Utilities

```typescript
// test/utils/flag-test-utils.ts

/**
 * Run a test body once for each flag state (on/off).
 * Useful for ensuring both code paths are exercised.
 */
export function forEachFlagState(
  flagKey: string,
  testFn: (flagValue: boolean) => Promise<void> | void
) {
  describe(`when ${flagKey} is ON`, () => {
    it("works correctly", async () => {
      const provider = setupTestProvider({ [flagKey]: true });
      await testFn(true);
    });
  });

  describe(`when ${flagKey} is OFF`, () => {
    it("works correctly", async () => {
      const provider = setupTestProvider({ [flagKey]: false });
      await testFn(false);
    });
  });
}

/**
 * Assert that a function's behavior varies based on a flag.
 * If both paths return the same result, the flag may be dead code.
 */
export async function assertFlagChangesOutput<T>(
  flagKey: string,
  action: () => Promise<T>
): Promise<{ whenOn: T; whenOff: T }> {
  setupTestProvider({ [flagKey]: true });
  const whenOn = await action();

  setupTestProvider({ [flagKey]: false });
  const whenOff = await action();

  if (JSON.stringify(whenOn) === JSON.stringify(whenOff)) {
    console.warn(
      `⚠ Flag "${flagKey}" does not change the output of the action. ` +
        `Consider removing the flag if it's no longer needed.`
    );
  }

  return { whenOn, whenOff };
}

/**
 * Snapshot-test both flag states to catch unexpected regressions.
 */
export function snapshotBothStates(
  flagKey: string,
  action: () => Promise<unknown>
) {
  it(`snapshot when ${flagKey}=ON`, async () => {
    setupTestProvider({ [flagKey]: true });
    const result = await action();
    expect(result).toMatchSnapshot();
  });

  it(`snapshot when ${flagKey}=OFF`, async () => {
    setupTestProvider({ [flagKey]: false });
    const result = await action();
    expect(result).toMatchSnapshot();
  });
}
```

### CI Pipeline Integration

**GitHub Actions — run tests against all flag environments:**

```yaml
# .github/workflows/flag-aware-tests.yml
name: Flag-Aware Tests

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        flag-profile:
          - all-flags-off      # baseline — production defaults
          - all-flags-on       # verify all new paths work
          - production-current # mirror of current prod flag state
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm

      - run: npm ci

      - name: Run unit tests with flag profile
        run: npm test -- --reporter=verbose
        env:
          FLAG_PROFILE: ${{ matrix.flag-profile }}

  pairwise-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm
      - run: npm ci

      - name: Generate pairwise flag matrix
        run: npx tsx scripts/generate-flag-matrix.ts

      - name: Run pairwise combination tests
        run: npm run test:pairwise -- --reporter=verbose

  integration-tests:
    runs-on: ubuntu-latest
    services:
      flagd:
        image: ghcr.io/open-feature/flagd:latest
        ports:
          - 8013:8013
        options: >-
          --mount type=bind,source=${{ github.workspace }}/config/flags/test.flagd.json,target=/flags.json
          --entrypoint flagd
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm
      - run: npm ci

      - name: Wait for flagd
        run: |
          for i in $(seq 1 30); do
            curl -s http://localhost:8013/flagd.evaluation.v1.Service/ResolveBoolean && break
            sleep 1
          done

      - name: Run integration tests
        run: npm run test:integration
        env:
          FLAGD_HOST: localhost
          FLAGD_PORT: 8013

  contract-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm
      - run: npm ci

      - name: Run contract tests
        run: npm run test:contracts

      - name: Publish pacts
        if: github.ref == 'refs/heads/main'
        run: npx pact-broker publish ./pacts --consumer-app-version=${{ github.sha }}
        env:
          PACT_BROKER_BASE_URL: ${{ secrets.PACT_BROKER_URL }}
          PACT_BROKER_TOKEN: ${{ secrets.PACT_BROKER_TOKEN }}

  flag-schema-validation:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Install dependencies
        run: pip install jsonschema pyyaml

      - name: Validate all flag config files
        run: python scripts/validate-flag-configs.py config/flags/
```

**Syncing production flag state to CI:**

```yaml
# .github/workflows/sync-prod-flags.yml
name: Sync Production Flag State

on:
  schedule:
    - cron: "0 */6 * * *"  # every 6 hours
  workflow_dispatch:

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Fetch current production flags
        run: |
          curl -s -H "Authorization: Bearer ${{ secrets.FLAG_SERVICE_TOKEN }}" \
            "${{ secrets.FLAG_SERVICE_URL }}/api/v1/flags" \
            | jq '.' > config/flags/production-current.json

      - name: Check for changes
        id: diff
        run: |
          if git diff --quiet config/flags/production-current.json; then
            echo "changed=false" >> "$GITHUB_OUTPUT"
          else
            echo "changed=true" >> "$GITHUB_OUTPUT"
          fi

      - name: Commit updated flag state
        if: steps.diff.outputs.changed == 'true'
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add config/flags/production-current.json
          git commit -m "chore: sync production flag state"
          git push
```

---

## Quick Reference: Which Test Type When?

| Scenario                          | Test Type           | Tool / Approach                 |
| --------------------------------- | ------------------- | ------------------------------- |
| Does my code handle both paths?   | Unit test           | Mock provider, both states      |
| Do flags interact unexpectedly?   | Pairwise combo test | allpairspy, PICT                |
| Does the flag service work e2e?   | Integration test    | Docker Compose + flagd/Unleash  |
| Are targeting rules correct?      | Eval logic test     | Unit test evaluator directly    |
| Do service and consumer agree?    | Contract test       | Pact, schema validation         |
| Is flag eval fast enough?         | Benchmark / load    | vitest bench, pytest-benchmark  |
| Can we safely roll back?          | Rollback test       | Flip flags, assert old behavior |
| Does the system survive chaos?    | Chaos test          | Random flag flipper             |
| Are test data shapes correct?     | Fixture test        | Flag-aware factories            |
| Does CI cover all flag states?    | Pipeline config     | Matrix builds, flag profiles    |

---

## Further Reading

- [OpenFeature Specification](https://openfeature.dev/specification/) — vendor-neutral flag evaluation API
- [flagd Documentation](https://flagd.dev/) — lightweight, open-source flag service
- [PICT (Pairwise Independent Combinatorial Testing)](https://github.com/microsoft/pict) — Microsoft's combinatorial test tool
- [allpairspy](https://pypi.org/project/allpairspy/) — Python pairwise test generation
- [Pact Contract Testing](https://docs.pact.io/) — consumer-driven contract testing
- [Testing in Production](https://launchdarkly.com/blog/testing-in-production/) — strategies for flag-driven production testing
