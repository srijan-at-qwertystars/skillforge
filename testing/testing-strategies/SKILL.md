---
name: testing-strategies
description: |
  Use when user designs test suites, asks about test pyramid, testing trophy, test doubles (mocks/stubs/spies), property-based testing, mutation testing, TDD, or test architecture decisions.
  Do NOT use for pytest specifics (use pytest-patterns skill), Playwright E2E (use playwright-e2e-testing skill), or load testing (use load-testing-k6 skill).
---

# Testing Strategies & Architecture

## Test Suite Shapes: Pyramid vs Trophy vs Diamond

### Test Pyramid (Cohn)
- **Shape:** Many unit tests → fewer integration → fewest E2E.
- **Strength:** Fast feedback, cheap to run, catches logic errors early.
- **Weakness:** Over-reliance on units gives false confidence — misses integration failures.
- **Use for:** Monoliths, libraries, pure-logic-heavy codebases.

### Testing Trophy (Dodds)
- **Shape:** Static analysis → few unit → many integration → few E2E.
- **Strength:** Integration tests catch real-world bugs at service boundaries.
- **Weakness:** Integration tests are slower and need more environment setup.
- **Use for:** Web apps, APIs, modern full-stack applications.

### Testing Diamond
- **Shape:** Unit base → wide integration middle → narrow E2E top.
- **Strength:** Emphasizes service boundary testing critical in distributed systems.
- **Weakness:** Risk of slow suites if integration tests are poorly designed.
- **Use for:** Microservices, event-driven architectures, distributed systems.

### Choosing a Shape
- Match shape to architecture risk profile. Boundaries fail most in microservices → favor diamond/trophy.
- Monoliths with complex logic → favor pyramid.
- Always include static analysis regardless of shape.

## Unit Testing Principles

### FIRST Properties
- **Fast:** Milliseconds per test. No I/O, no network.
- **Isolated:** No shared state between tests. Each test sets up and tears down independently.
- **Repeatable:** Same result every run. No randomness, no time-dependence without control.
- **Self-validating:** Pass or fail — no manual inspection of output.
- **Timely:** Write tests close in time to the code they verify.

### Arrange-Act-Assert (AAA)
```python
def test_discount_applied_to_order():
    # Arrange
    order = Order(items=[Item(price=100)], coupon="SAVE10")

    # Act
    total = order.calculate_total()

    # Assert
    assert total == 90
```

### Given-When-Then (BDD style)
```typescript
describe("Order discount", () => {
  it("applies percentage coupon to total", () => {
    // Given
    const order = new Order([{ price: 100 }], "SAVE10");

    // When
    const total = order.calculateTotal();

    // Then
    expect(total).toBe(90);
  });
});
```

### Isolation Rules
- Test one behavior per test. Multiple asserts are fine if they verify the same behavior.
- Never let test A's outcome affect test B.
- Use test doubles for external dependencies, not for the unit under test.

## Integration Testing

### What to Integration-Test
- Database queries and migrations (use real DB or Testcontainers).
- HTTP API request/response cycles.
- Service-to-service communication across boundaries.
- Message queue publish/consume flows.

### Testcontainers Pattern
```java
@Testcontainers
class UserRepositoryTest {
    @Container
    static PostgreSQLContainer<?> pg = new PostgreSQLContainer<>("postgres:16");

    @Test
    void findsUserByEmail() {
        var repo = new UserRepository(pg.getJdbcUrl());
        repo.save(new User("alice@example.com"));

        var found = repo.findByEmail("alice@example.com");

        assertThat(found).isPresent();
        assertThat(found.get().email()).isEqualTo("alice@example.com");
    }
}
```

### API Integration Test
```python
def test_create_user_returns_201(client):
    response = client.post("/users", json={"email": "a@b.com", "name": "A"})

    assert response.status_code == 201
    assert response.json()["email"] == "a@b.com"
```

### Guidelines
- Use real dependencies (databases, caches) via containers — avoid mocking datastores in integration tests.
- Keep integration tests focused on boundary behavior, not internal logic.
- Isolate test data per test. Use transactions that roll back, or unique identifiers.

## Test Doubles

### When to Use Each Type

| Double | Purpose | Example |
|--------|---------|---------|
| **Dummy** | Fill a required parameter never actually used | `new Service(dummyLogger)` |
| **Stub** | Return canned data to control test flow | `stub(repo.find).returns(user)` |
| **Spy** | Record calls for later assertion | `verify(spy.send).calledWith(email)` |
| **Mock** | Pre-programmed expectations; fails if not met | `mock.expect("save").once()` |
| **Fake** | Working simplified implementation | In-memory repository, fake SMTP server |

### Decision Rules
- **Default to stubs.** Use stubs when you only care about outputs.
- **Use spies** when verifying side effects (email sent, event published).
- **Use mocks sparingly.** They couple tests to implementation — prefer state verification over interaction verification.
- **Use fakes** for complex dependencies where stubs become unwieldy (databases, file systems).
- **Never mock what you don't own.** Wrap third-party APIs behind your own interface, then mock that.

```typescript
// Stub example (Jest)
const repo = { findById: jest.fn().mockResolvedValue({ id: 1, name: "Alice" }) };
const service = new UserService(repo);
const user = await service.getUser(1);
expect(user.name).toBe("Alice");

// Spy example (Jest)
const notifier = { send: jest.fn() };
await service.deactivateUser(1, notifier);
expect(notifier.send).toHaveBeenCalledWith(expect.objectContaining({ type: "deactivated" }));
```

## Contract Testing

### Consumer-Driven Contracts (Pact)
1. **Consumer** writes a Pact test defining expected interactions.
2. Pact generates a contract file (JSON).
3. **Provider** verifies the contract in its own CI pipeline.
4. **Pact Broker** stores contracts, enables `can-i-deploy` checks.

```javascript
// Consumer Pact test (JS)
const interaction = {
  state: "user 1 exists",
  uponReceiving: "a request for user 1",
  withRequest: { method: "GET", path: "/users/1" },
  willRespondWith: {
    status: 200,
    body: like({ id: 1, name: string("Alice") }),
  },
};
```

### Guidelines
- Run contract verification on every provider build before deploy.
- Use provider states to set up test data dynamically.
- Version contracts with SemVer. Breaking changes = major version bump.
- Contract tests replace some integration tests — they do NOT replace E2E.

## Property-Based Testing

### Core Concepts
- **Property:** An invariant that holds for all valid inputs — e.g., `sort(xs).length === xs.length`.
- **Generator/Arbitrary:** Produces random inputs conforming to constraints.
- **Shrinking:** On failure, the framework minimizes the failing input to the simplest counterexample.

### Property Patterns
- **Round-trip:** `decode(encode(x)) === x`
- **Idempotency:** `f(f(x)) === f(x)`
- **Invariant preservation:** Output always satisfies a constraint.
- **Oracle/reference:** Compare against a known-correct (but slow) implementation.
- **Metamorphic:** Predictable output change from predictable input change.

### fast-check (TypeScript)
```typescript
import fc from "fast-check";

test("sort is idempotent", () => {
  fc.assert(
    fc.property(fc.array(fc.integer()), (arr) => {
      const sorted = arr.slice().sort((a, b) => a - b);
      const sortedTwice = sorted.slice().sort((a, b) => a - b);
      expect(sorted).toEqual(sortedTwice);
    })
  );
});
```

### Hypothesis (Python)
```python
from hypothesis import given
from hypothesis import strategies as st

@given(st.lists(st.integers()))
def test_sort_preserves_length(xs):
    assert len(sorted(xs)) == len(xs)
```

### Guidelines
- Start with simple properties (length preservation, round-trips).
- Write custom generators for domain objects — avoid excessive `.filter()`.
- Set `max_examples` / time limits for CI. Default 100 examples is often sufficient.
- Property tests complement example-based tests — use both.

## Mutation Testing

### How It Works
1. Tool introduces small code changes (mutants): `+` → `-`, `>` → `>=`, `true` → `false`.
2. Test suite runs against each mutant.
3. **Killed:** Tests caught the mutation (good). **Survived:** Tests missed it (gap).
4. **Mutation score** = killed / (total − equivalent mutants) × 100%.

### Tools
- **Stryker** (JS/TS/C#): `npx stryker run`. Configure `thresholds: { high: 80, low: 60, break: 50 }`.
- **PIT/pitest** (Java): Maven/Gradle plugin. `mvn org.pitest:pitest-maven:mutationCoverage`.

### Equivalent Mutants
- Mutants that produce identical behavior for all inputs (e.g., `x * 1` → `x * -1` when x is always 0).
- Cannot be fully auto-detected. Review survived mutants manually.
- Target 70–85% mutation score. 100% is impractical.

### Guidelines
- Focus mutation testing on business logic, not generated code or config.
- Run incrementally in CI to avoid long feedback cycles.
- Use mutation score as a quality indicator alongside (not replacing) coverage.

## Snapshot Testing

### When Useful
- Serialized output stability: API responses, rendered HTML, CLI output.
- Detecting unintended changes in complex nested structures.
- **Approval testing** variant: human reviews and approves new snapshots.

### Anti-Patterns
- Snapshots of volatile data (timestamps, random IDs) → constant false failures.
- Blindly updating snapshots without reviewing diffs.
- Using snapshots as the sole verification — they test "nothing changed," not "this is correct."

### Guidelines
- Keep snapshots small and focused. Snapshot one component, not an entire page.
- Use inline snapshots for small outputs, file-based for large ones.
- Pair with assertion-based tests for correctness verification.

## TDD Workflow

### Red-Green-Refactor
1. **Red:** Write a failing test that defines the next behavior.
2. **Green:** Write the minimum code to pass. Resist premature design.
3. **Refactor:** Clean up duplication and structure. All tests stay green.
4. **Commit.** Micro-commits after each cycle.

### Outside-In TDD
- Start with an acceptance test at the feature/API boundary.
- Drive implementation inward, creating collaborators as needed.
- Best for feature delivery — ensures architecture serves user needs.

### Inside-Out TDD
- Start with low-level units (domain objects, utilities).
- Build upward to higher-level integrations.
- Best for libraries, algorithms, well-understood domains.

### When NOT to TDD
- Throwaway prototypes and spikes exploring unknown problem spaces.
- UI layout/animation (test behavior, not pixels).
- Legacy code without existing test coverage — write characterization tests first.
- When requirements are unclear — clarify before committing to test structure.

## Test Organization

### Naming Convention
Use `test_<unit>_<scenario>_<expected>` or `should <behavior> when <condition>`:
```
test_calculate_total_with_discount_returns_reduced_price
should return 404 when user not found
```

### File Structure
```
src/
  user/
    user.service.ts
    user.repository.ts
tests/
  unit/
    user/
      user.service.test.ts
  integration/
    user/
      user.repository.test.ts
  e2e/
    user.e2e.test.ts
```
Alternative: colocate test files next to source (`user.service.test.ts` beside `user.service.ts`).

### Shared Fixtures & Factories
- Prefer **test factories** over shared fixtures — factories are explicit and composable.
- Use builder pattern for complex objects:
```typescript
const user = UserFactory.build({ role: "admin", verified: true });
```
- Avoid global `beforeAll` setup that creates hidden dependencies between tests.

## Flaky Test Management

### Common Causes
- Shared mutable state between tests.
- Time-dependent logic (`Date.now()`, timeouts, sleep).
- Network calls to external services.
- Test order dependence.
- Race conditions in async code.

### Detection
- Run suite multiple times in CI (repeat mode). Flag tests that intermittently fail.
- Track pass/fail history per test. Statistical flakiness detection over N runs.

### Quarantine Strategy
1. Move flaky test to a quarantine suite (runs separately, non-blocking).
2. Fix root cause within a defined SLA (e.g., 1 sprint).
3. Return to main suite once stable. Delete if unfixable and low-value.

### Fixing Strategies
- Replace `sleep()` with polling/`waitFor` patterns.
- Inject clocks and control time explicitly.
- Eliminate shared state — each test creates its own data.
- Mock or containerize external dependencies.

## Coverage Metrics

### Types
- **Line coverage:** Which lines executed. Minimum useful metric.
- **Branch coverage:** Which `if`/`else` paths taken. Catches missed conditions.
- **Condition coverage:** Each boolean sub-expression evaluated both true and false.
- **MC/DC (Modified Condition/Decision):** Each condition independently affects the outcome. Used in safety-critical systems.

### Meaningful Coverage
- High coverage ≠ well-tested. Tests can execute code without asserting behavior.
- Mutation score is the better quality indicator.
- Use coverage to find **untested** code, not to prove code is **well-tested.**

### Coverage Ratchet
- Record current coverage percentage. CI fails if new commits lower it.
- Ratchet up incrementally — never allow regression.
```yaml
# Example: Jest config
coverageThreshold:
  global:
    branches: 80
    functions: 85
    lines: 85
```

## CI Test Optimization

### Parallelization
- Split suite across N workers by estimated runtime, not file count.
- Ensure tests are isolated — no shared database state, no file system collisions.
- Formula: `shard_count = ceil(total_suite_time / target_time_per_shard)`.

### Test Splitting
```bash
# Jest sharding
npx jest --shard=1/4  # worker 1 of 4
npx jest --shard=2/4  # worker 2 of 4
```

### Test Impact Analysis (TIA)
- Map code changes to affected tests via dependency graph.
- Run only impacted tests on feature branches. Run full suite on main.
- Tools: Nx affected, Bazel, Gradle's test distribution, Azure TIA.

### Selective Testing
- Unit tests: every commit.
- Integration tests: every PR or merge.
- E2E tests: pre-deploy, nightly, or on critical-path changes.

### Pipeline Structure
```
commit → lint + type-check → unit tests (parallel) → integration tests → deploy staging → E2E smoke → deploy prod
```

## Anti-Patterns

### Testing Implementation Details
- **Problem:** Tests break on refactor even when behavior is unchanged.
- **Fix:** Test inputs/outputs and observable side effects, not internal method calls or private state.

### Brittle Tests
- **Problem:** Tests break from unrelated changes (CSS selectors, JSON key order).
- **Fix:** Use semantic selectors (`data-testid`, roles). Assert on structure, not serialization order.

### Slow Test Suites
- **Problem:** Suite takes 30+ minutes → developers skip tests or batch commits.
- **Fix:** Parallelize, use TIA, move slow tests to separate pipeline stages.

### Test Interdependence
- **Problem:** Test B fails only when Test A runs first.
- **Fix:** Randomize test order. Each test owns its setup and teardown.

### Excessive Mocking
- **Problem:** Tests pass but production breaks — mocks don't match real behavior.
- **Fix:** Use fakes or containers for complex dependencies. Mock only at the boundary.

### Ice Cream Cone (Inverted Pyramid)
- **Problem:** Most tests are E2E, few are unit → slow, flaky, expensive.
- **Fix:** Push verification down. If a unit test can catch it, don't test it in E2E.
