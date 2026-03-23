---
name: api-contract-testing
description:
  positive: "Use when user implements contract testing between services, asks about Pact (consumer-driven contracts), OpenAPI/Swagger schema validation, provider verification, contract broker, or testing microservice API boundaries."
  negative: "Do NOT use for unit testing, integration testing with live services, end-to-end testing, or general API design (use graphql-schema-design skill for GraphQL)."
---

# API Contract Testing

## What Contract Testing Solves

Contract testing verifies that two services (consumer and provider) can communicate correctly by testing the API boundary in isolation. It fills the gap between unit tests and E2E tests.

| Approach | Scope | Speed | Reliability | Environment needed |
|----------|-------|-------|-------------|-------------------|
| Unit tests | Single function/class | ms | High | None |
| Contract tests | API boundary between two services | seconds | High | None (mocked) |
| Integration tests | Multiple live services | minutes | Medium | Staging/shared |
| E2E tests | Full system | minutes-hours | Low (flaky) | Full environment |

**Use contract tests when:** multiple teams own different services, deploying independently, E2E tests are slow/flaky, or need fast API compatibility feedback.

**Do NOT use contract tests to verify:** business logic, data transformations, or full workflow correctness.

## Consumer-Driven Contracts with Pact

### Core Concept

The **consumer** defines expected interactions (request → response pairs). These become the **contract** (pact file). The **provider** verifies it can fulfill every interaction.

### Workflow

```
1. Consumer writes test defining expected interactions
2. Pact generates contract file (JSON)
3. Contract published to Pact Broker
4. Provider verifies contract against its real implementation
5. Verification results published to Broker
6. `can-i-deploy` gates deployment based on verification status
```

## Writing Consumer Tests

### JavaScript / TypeScript (PactV4)

```javascript
import { PactV4, MatchersV3 } from '@pact-foundation/pact';
const { like, eachLike, string, integer } = MatchersV3;

const provider = new PactV4({
  consumer: 'OrderService',
  provider: 'UserService',
});

describe('User API', () => {
  it('returns user by ID', async () => {
    await provider
      .addInteraction()
      .given('user 42 exists')
      .uponReceiving('a request for user 42')
      .withRequest('GET', '/users/42')
      .willRespondWith(200, (builder) => {
        builder
          .headers({ 'Content-Type': 'application/json' })
          .jsonBody({
            id: integer(42),
            name: string('Jane Doe'),
            email: string('jane@example.com'),
          });
      })
      .executeTest(async (mockServer) => {
        const response = await fetch(`${mockServer.url}/users/42`);
        const user = await response.json();
        expect(user.id).toBe(42);
        expect(user.name).toBeDefined();
      });
  });
});
```

### Python

```python
from pact import Consumer, Provider, Like

pact = Consumer('OrderService').has_pact_with(Provider('UserService'), pact_dir='./pacts')
pact.start_service()

class TestUserService(unittest.TestCase):
    def test_get_user(self):
        (pact
         .given('user 42 exists')
         .upon_receiving('a request for user 42')
         .with_request('GET', '/users/42')
         .will_respond_with(200, body=Like({'id': 42, 'name': 'Jane Doe'})))
        with pact:
            result = fetch_user(pact.uri, 42)
            assert result['id'] == 42
```

### Java (JUnit 5)

```java
@ExtendWith(PactConsumerTestExt.class)
@PactTestFor(providerName = "UserService")
class UserContractTest {
    @Pact(consumer = "OrderService")
    V4Pact getUserPact(PactDslWithProvider builder) {
        return builder
            .given("user 42 exists")
            .uponReceiving("a request for user 42")
            .path("/users/42").method("GET")
            .willRespondWith().status(200)
            .body(newJsonBody(b -> {
                b.integerType("id", 42);
                b.stringType("name", "Jane Doe");
            }).build())
            .toPact(V4Pact.class);
    }

    @Test @PactTestFor(pactMethod = "getUserPact")
    void testGetUser(MockServer mockServer) {
        User user = new UserClient(mockServer.getUrl()).getUser(42);
        assertThat(user.getId()).isEqualTo(42);
    }
}
```

### Go

```go
func TestConsumerGetUser(t *testing.T) {
    mockProvider, _ := consumer.NewV4Pact(consumer.MockHTTPProviderConfig{
        Consumer: "OrderService", Provider: "UserService",
    })
    mockProvider.AddInteraction().
        Given("user 42 exists").
        UponReceiving("a request for user 42").
        WithCompleteRequest(consumer.Request{Method: "GET", Path: matchers.String("/users/42")}).
        WithCompleteResponse(consumer.Response{
            Status: 200,
            Body:   matchers.Map{"id": matchers.Integer(42), "name": matchers.String("Jane Doe")},
        }).
        ExecuteTest(t, func(config consumer.MockServerConfig) error {
            user, err := GetUser(config.URL, 42)
            assert.Equal(t, 42, user.ID)
            return err
        })
}
```

### Matcher Best Practices

Use matchers to avoid brittle contracts:

| Matcher | Purpose | Example |
|---------|---------|---------|
| `like()` | Match type, not value | `like(42)` matches any integer |
| `eachLike()` | Array with typed elements | `eachLike({id: 1})` |
| `regex()` | Match pattern | `regex('2024-\\d{2}-\\d{2}', '2024-01-15')` |
| `integer()` | Integer type | `integer(42)` |
| `decimal()` | Decimal type | `decimal(3.14)` |
| `boolean()` | Boolean type | `boolean(true)` |
| `datetime()` | ISO datetime | `datetime("yyyy-MM-dd'T'HH:mm:ss")` |

**Rule:** Match on structure and types. Only match exact values when the consumer truly depends on them (e.g., enum values, status codes).

## Provider Verification

### Provider States

Provider states set up test data before each interaction is replayed. Implement a state handler:

```javascript
// provider.spec.js
const { Verifier } = require('@pact-foundation/pact');

new Verifier({
  providerBaseUrl: 'http://localhost:3000',
  pactBrokerUrl: 'https://broker.example.com',
  provider: 'UserService',
  providerVersion: process.env.GIT_SHA,
  providerVersionBranch: process.env.GIT_BRANCH,
  publishVerificationResult: true,
  stateHandlers: {
    'user 42 exists': async () => {
      await db.insert({ id: 42, name: 'Jane Doe', email: 'jane@example.com' });
    },
    'no users exist': async () => {
      await db.clear('users');
    },
  },
}).verifyProvider();
```

### Pending Pacts

Pending pacts prevent new consumer expectations from breaking the provider build. Enable them:

```javascript
new Verifier({
  // ...
  enablePending: true,
  consumerVersionSelectors: [
    { mainBranch: true },
    { deployedOrReleased: true },
  ],
});
```

- **Pending pacts**: New pacts that haven't been verified yet. Failures are warnings, not errors.
- **WIP pacts**: Pacts from branches not yet merged. Automatically included for verification without breaking the provider.

### Consumer Version Selectors

Control which pacts to verify:

```javascript
consumerVersionSelectors: [
  { mainBranch: true },           // latest from main/master
  { deployedOrReleased: true },   // currently in production
  { branch: 'feat/new-endpoint' }, // specific feature branch
  { matchingBranch: true },       // same branch name as provider
]
```

## Pact Broker

### Publishing Contracts

```bash
pact-broker publish ./pacts \
  --consumer-app-version=$(git rev-parse HEAD) \
  --branch=$(git branch --show-current) \
  --broker-base-url=https://broker.example.com \
  --broker-token=$PACT_BROKER_TOKEN
```

### can-i-deploy

Gate deployments on contract compatibility:

```bash
pact-broker can-i-deploy \
  --pacticipant=UserService \
  --version=$(git rev-parse HEAD) \
  --to-environment=production \
  --broker-base-url=https://broker.example.com

# Record after successful deploy
pact-broker record-deployment \
  --pacticipant=UserService \
  --version=$(git rev-parse HEAD) \
  --environment=production
```

### Webhooks

Trigger provider verification when a contract changes:

```bash
pact-broker create-webhook https://ci.example.com/trigger-build \
  --request=POST \
  --header="Authorization: Bearer ${CI_TOKEN}" \
  --body='{"ref":"main","provider":"${pactbroker.providerName}"}' \
  --contract-requiring-verification-published \
  --broker-base-url=https://broker.example.com
```

Use the `contract_requiring_verification_published` event (not `contract_published`) to avoid redundant builds.

## OpenAPI/Swagger Schema Validation

Validate API responses against an OpenAPI spec without Pact:

### Using api-contract-validator (Jest)

```javascript
const { chaiPlugin } = require('api-contract-validator');
const apiSpec = path.join(__dirname, '../openapi.yaml');
chai.use(chaiPlugin({ apiDefinitionsPath: apiSpec }));

it('GET /users/:id matches OpenAPI spec', async () => {
  const res = await request(app).get('/users/42');
  expect(res).to.matchApiSchema();
});
```

### Using Ajv for JSON Schema Validation

```javascript
import Ajv from 'ajv';
import spec from './openapi.json';
const ajv = new Ajv();
const schema = spec.paths['/users/{id}'].get.responses['200'].content['application/json'].schema;

test('response matches schema', async () => {
  const data = await fetch('/users/42').then(r => r.json());
  expect(ajv.compile(schema)(data)).toBe(true);
});
```

### Using Dredd

```bash
dredd openapi.yaml http://localhost:3000 --hookfiles=./dredd-hooks.js
```

**OpenAPI validation vs Pact:**
- OpenAPI validation: provider-side only, checks spec compliance
- Pact: consumer-driven, tests actual consumer expectations
- Use both: OpenAPI for provider correctness, Pact for consumer compatibility

## Bi-Directional Contract Testing (Pactflow)

Bi-directional contract testing decouples consumer and provider tooling:

```
Consumer (Pact/WireMock/Nock/MSW) → consumer contract ─┐
                                                        ├→ Pactflow → cross-compare → can-i-deploy
Provider (OpenAPI spec + test results) → provider contract ─┘
```

**When to use BDCT over CDCT:** provider already has an OpenAPI spec, teams use different stacks, integrating with third-party APIs, or reducing cross-team coordination overhead.

**Provider contract generation:**

```bash
pactflow publish-provider-contract openapi.yaml \
  --provider=UserService \
  --provider-app-version=$(git rev-parse HEAD) \
  --branch=main \
  --verification-results=test-results.json \
  --verification-results-format=junit
```

## CI/CD Integration Patterns

### GitHub Actions Example

```yaml
# Consumer pipeline
consumer-contract-test:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - run: npm test -- --testPathPattern=pact
    - run: |
        npx pact-broker publish ./pacts \
          --consumer-app-version=${{ github.sha }} \
          --branch=${{ github.ref_name }} \
          --broker-base-url=${{ secrets.PACT_BROKER_URL }} \
          --broker-token=${{ secrets.PACT_BROKER_TOKEN }}
    - run: |
        npx pact-broker can-i-deploy \
          --pacticipant=OrderService \
          --version=${{ github.sha }} \
          --to-environment=production

# Provider pipeline
provider-verification:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - run: npm start &
    - run: npx jest --testPathPattern=provider.pact
```

### Pipeline Flow

```
Consumer commit → run consumer tests → publish pact → can-i-deploy → deploy
                                           ↓ (webhook)
Provider commit → run provider tests → verify pacts → publish results → can-i-deploy → deploy
```

**Key rules:** Always publish verification results. Tag versions with branch/environment. Use `can-i-deploy` as a hard gate. Use `record-deployment` after every deploy.

## Contract Testing for Async / Event-Driven Systems

### Pact Message Testing

Test event producers and consumers without a broker or transport layer:

**Message Consumer Test (JS):**

```javascript
const { MessageConsumerPact, synchronousBodyHandler } = require('@pact-foundation/pact');
const messagePact = new MessageConsumerPact({
  consumer: 'NotificationService', provider: 'OrderService', dir: './pacts',
});

describe('order.created event', () => {
  it('processes order created message', () => {
    return messagePact
      .given('an order has been created')
      .expectsToReceive('an order.created event')
      .withContent({
        orderId: like('ord-123'),
        userId: like('usr-456'),
        total: decimal(99.99),
        createdAt: datetime("yyyy-MM-dd'T'HH:mm:ss'Z'"),
      })
      .withMetadata({ topic: 'orders', contentType: 'application/json' })
      .verify(synchronousBodyHandler(handleOrderCreated));
  });
});
```

**Message Provider Verification:**

```javascript
new Verifier({
  provider: 'OrderService',
  pactBrokerUrl: 'https://broker.example.com',
  messageProviders: {
    'an order.created event': () =>
      createOrderEvent({ id: 'ord-123', userId: 'usr-456', total: 99.99 }),
  },
}).verifyProvider();
```

Supported transports: Kafka, RabbitMQ, SQS, SNS, Azure Service Bus. Pact abstracts transport — tests message content only.

## Schema Evolution and Backward Compatibility

### Safe Changes (Non-Breaking)

- Add optional fields to responses, new endpoints, or optional query parameters
- Widen accepted input types

### Breaking Changes

- Remove/rename fields, change types, remove endpoints, make optional fields required

### Migration Strategy

```
1. Deploy provider with NEW field (old field still present)
2. Update consumers to use new field
3. Verify all consumers no longer reference old field (check Broker)
4. Remove old field from provider
5. Verify contracts still pass
```

Use `can-i-deploy` at each step. Never remove fields until all deployed consumers have stopped depending on them.

### Versioning

- **URL versioning** (`/v1/users`, `/v2/users`): explicit
- **Header versioning** (`Accept: application/vnd.api.v2+json`): cleaner URLs
- **Additive-only**: avoid versioning by never breaking contracts (preferred)

## Common Patterns and Anti-Patterns

### Do

- Test only what consumers need — not every provider endpoint
- Use matchers liberally — match types/shapes, not exact values
- One consumer test per interaction — keep tests focused
- Minimal provider states — only data needed for each interaction
- Use `consumerVersionSelectors` to verify relevant pact versions only
- Run contract tests on every commit

### Avoid

- Testing provider business logic in consumer tests
- Using Pact as an E2E tool (no chained multi-provider calls)
- Over-specifying contracts with exact values when types suffice
- Sharing pact files via git (use Pact Broker)
- Skipping `can-i-deploy` before deployments
- Verifying against mocks instead of the real provider
- One giant pact for all interactions (split by feature)

## Testing Strategy: Which Tests at Which Layer

```
         ╱╲          E2E: few critical paths (5-10%)
        ╱──╲
       ╱Ctrct╲       Contract: API boundaries (15-20%)
      ╱────────╲
     ╱Integration╲   Integration: DB, queues (20-25%)
    ╱──────────────╲
   ╱   Unit Tests   ╲ Unit: logic, transforms (50-60%)
  ╱__________________╲
```

**Contract tests replace most integration tests that exist solely to verify API compatibility.** Keep integration tests for real databases/brokers. Keep E2E tests for critical business flows only.

### Decision Matrix

| Scenario | Test type |
|----------|-----------|
| Does my function return correct output? | Unit test |
| Does my service connect to the DB correctly? | Integration test |
| Can Service A call Service B's API correctly? | **Contract test** |
| Does the full checkout flow work? | E2E test |
| Does the provider response match the OpenAPI spec? | Schema validation |
| Can I deploy this version safely? | `can-i-deploy` |
