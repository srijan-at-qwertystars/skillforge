---
name: temporal-workflows
description: >
  Build and debug Temporal durable workflow applications across TypeScript, Go, and Python SDKs.
  TRIGGER when: user mentions Temporal, durable execution, workflow orchestration, task queues,
  workflow replay, temporal server, temporal CLI, workflow signals/queries, activity retries,
  workflow versioning/patching, saga compensation, child workflows, workflow schedules,
  or imports from @temporalio/*, go.temporal.io/sdk, or temporalio Python package.
  DO NOT TRIGGER when: user works with other workflow engines (Airflow, Prefect, Step Functions,
  Argo, Conductor), general async/await without Temporal, plain cron jobs, or message queues
  (RabbitMQ, Kafka) without Temporal context.
---

# Temporal Workflow Engine

## Architecture

Temporal consists of: **Temporal Server** (orchestrator, persists workflow state via event history), **Workers** (user-hosted processes polling task queues), **Clients** (start workflows, send signals, run queries), and **Namespaces** (logical isolation).

- Server components: Frontend, History, Matching, Internal Worker services
- Workers poll a **Task Queue** (string ID). Multiple workers poll the same queue for horizontal scaling
- Workflow state lives as append-only **Event History** in the server, never in workers
- **Web UI** at `localhost:8233` (dev server) for inspecting workflows

## Workflow Definition

Workflows are deterministic functions. Temporal replays event history through workflow code on recovery. Every execution with the same history must produce identical commands.

### Determinism Rules — NEVER do these inside workflow code:
- Call `Date.now()`, `Math.random()`, or `uuid()` — use SDK equivalents
- Perform I/O (network, filesystem, database) — delegate to activities
- Use non-deterministic language constructs (Go: goroutines without `workflow.Go`; TS: native `setTimeout`)
- Mutate global/shared state; use non-deterministic iteration order (unordered maps in Go)

### Replay Safety
On worker restart, Temporal replays event history. Completed activities/timers return recorded results. New commands generate only past the replay point.

## Activities

Activities perform non-deterministic work: HTTP calls, database queries, file I/O, sending emails.

**Timeouts** (set at least one): `StartToCloseTimeout` (max single attempt), `ScheduleToCloseTimeout` (max including retries), `ScheduleToStartTimeout` (max queue wait), `HeartbeatTimeout` (must heartbeat within interval).

**Heartbeats** — Long-running activities call heartbeat to report progress. On retry, last heartbeat details are available:
```typescript
export async function processLargeFile(path: string): Promise<number> {
  const lines = await readLines(path);
  const startLine = activity.Context.current().info.heartbeatDetails ?? 0;
  for (let i = startLine; i < lines.length; i++) {
    await processLine(lines[i]);
    activity.Context.current().heartbeat(i);
  }
  return lines.length;
}
```

## TypeScript SDK

Packages: `@temporalio/workflow`, `@temporalio/activity`, `@temporalio/worker`, `@temporalio/client`.

### Activity Definition (`activities.ts`)
```typescript
export async function greet(name: string): Promise<string> { return `Hello, ${name}!`; }
export async function sendEmail(to: string, body: string): Promise<void> { await emailService.send(to, body); }
```

### Workflow Definition (`workflows.ts`)
```typescript
import * as wf from '@temporalio/workflow';
import type * as activities from './activities';

const { greet, sendEmail } = wf.proxyActivities<typeof activities>({
  startToCloseTimeout: '30s',
  retry: { maximumAttempts: 3 },
});

export async function onboardUser(name: string, email: string): Promise<string> {
  const greeting = await greet(name);
  await sendEmail(email, greeting);
  return greeting;
}
```

### Worker Setup (`worker.ts`)
```typescript
import { Worker } from '@temporalio/worker';
import * as activities from './activities';

async function run() {
  const worker = await Worker.create({
    workflowsPath: require.resolve('./workflows'),
    activities,
    taskQueue: 'onboarding-queue',
  });
  await worker.run();
}
run().catch(console.error);
```

### Client Usage (`client.ts`)
```typescript
import { Client } from '@temporalio/client';

const client = new Client();
const handle = await client.workflow.start('onboardUser', {
  args: ['Alice', 'alice@example.com'],
  taskQueue: 'onboarding-queue',
  workflowId: 'onboard-alice',
});
const result = await handle.result();
// result: "Hello, Alice!"
```

## Go SDK

Package: `go.temporal.io/sdk`. Workflows and activities are plain Go functions.
```go
// Workflow
func OrderWorkflow(ctx workflow.Context, orderID string) (string, error) {
    ao := workflow.ActivityOptions{
        StartToCloseTimeout: 30 * time.Second,
        RetryPolicy: &temporal.RetryPolicy{
            InitialInterval: time.Second, BackoffCoefficient: 2.0, MaximumAttempts: 5,
        },
    }
    ctx = workflow.WithActivityOptions(ctx, ao)
    var result string
    err := workflow.ExecuteActivity(ctx, ProcessOrder, orderID).Get(ctx, &result)
    return result, err
}

// Activity
func ProcessOrder(ctx context.Context, orderID string) (string, error) {
    return fmt.Sprintf("processed-%s", orderID), nil
}

// Worker — register workflow + activity, then run
func main() {
    c, _ := client.Dial(client.Options{})
    defer c.Close()
    w := worker.New(c, "order-queue", worker.Options{})
    w.RegisterWorkflow(OrderWorkflow)
    w.RegisterActivity(ProcessOrder)
    w.Run(worker.InterruptCh())
}

// Client — start workflow and get result
we, _ := c.ExecuteWorkflow(ctx, client.StartWorkflowOptions{TaskQueue: "order-queue"}, OrderWorkflow, "order-123")
var result string
we.Get(ctx, &result) // result: "processed-order-123"
```

## Python SDK

Package: `temporalio`. Workflows are classes with decorators.
### Activity
```python
from temporalio import activity
from dataclasses import dataclass

@dataclass
class OrderInput:
    order_id: str
    amount: float

@activity.defn
async def charge_payment(input: OrderInput) -> str:
    return f"charged-{input.order_id}-{input.amount}"
```

### Workflow
```python
from temporalio import workflow
from datetime import timedelta

@workflow.defn
class PaymentWorkflow:
    @workflow.run
    async def run(self, input: OrderInput) -> str:
        return await workflow.execute_activity(
            charge_payment, input, start_to_close_timeout=timedelta(seconds=30))
```

### Worker and Client
```python
from temporalio.client import Client
from temporalio.worker import Worker

async def main():
    client = await Client.connect("localhost:7233")
    worker = Worker(client, task_queue="payment-queue",
                    workflows=[PaymentWorkflow], activities=[charge_payment])
    await worker.run()

# Start workflow:
result = await client.execute_workflow(
    PaymentWorkflow.run, OrderInput(order_id="order-123", amount=99.99),
    id="payment-order-123", task_queue="payment-queue")
# result: "charged-order-123-99.99"
```

## Signals, Queries, and Updates

### Signals — async messages that mutate workflow state
```typescript
export const approveSignal = wf.defineSignal<[string]>('approve');
export async function approvalWorkflow(): Promise<string> {
  let approver = '';
  wf.setHandler(approveSignal, (name: string) => { approver = name; });
  await wf.condition(() => approver !== '');
  return `Approved by ${approver}`;
}
// Client: handle.signal(approveSignal, 'manager@co.com')
```

### Queries — synchronous read-only state inspection
```typescript
export const statusQuery = wf.defineQuery<string>('status');
export async function trackedWorkflow(): Promise<void> {
  let status = 'started';
  wf.setHandler(statusQuery, () => status);
  await doWork();
  status = 'completed';
}
// Client: const s = await handle.query(statusQuery)
```

### Updates — validated signal + response
```typescript
export const updatePrice = wf.defineUpdate<number, [number]>('updatePrice');
wf.setHandler(updatePrice, (newPrice: number) => {
  if (newPrice < 0) throw new Error('Price must be positive');
  price = newPrice; return price;
});
```

## Child Workflows

Decompose complex orchestrations. Child workflows have independent event histories, reducing parent history size.
```typescript
import { startChild, executeChild } from '@temporalio/workflow';
export async function parentWorkflow(items: string[]): Promise<string[]> {
  const results: string[] = [];
  for (const item of items) {
    const r = await executeChild(processItemWorkflow, { args: [item] });
    results.push(r);
  }
  return results;
}
// Fire-and-forget: const handle = await startChild(childWf, { args: [item], workflowId: `child-${item}` });
```

```go
// Go — workflow.ExecuteChildWorkflow(ctx, ChildWorkflow, "input").Get(ctx, &result)
cwo := workflow.ChildWorkflowOptions{WorkflowID: "child-1"}
ctx = workflow.WithChildOptions(ctx, cwo)
```

## Timers and Sleep

`workflow.sleep` creates a durable timer — survives worker restarts. TS: `await sleep('7 days')`. Go: `workflow.Sleep(ctx, 7*24*time.Hour)`. Python: `await workflow.sleep(timedelta(days=7))`.
```typescript
import { sleep } from '@temporalio/workflow';
export async function reminderWorkflow(userId: string): Promise<void> {
  await sendInitialEmail(userId);
  await sleep('7 days');
  await sendFollowUp(userId);
}
```

Use `wf.condition(fn, timeout)` (TS) for interruptible waits — returns `false` on timeout:
```typescript
const signaled = await wf.condition(() => approved, '24 hours');
if (!signaled) await handleTimeout();
```

## Error Handling and Compensation (Saga Pattern)

Implement compensating transactions when a multi-step workflow fails:
```typescript
export async function bookTripSaga(trip: TripInput): Promise<string> {
  const compensations: Array<() => Promise<void>> = [];
  try {
    const flightId = await bookFlight(trip);
    compensations.push(() => cancelFlight(flightId));
    const hotelId = await bookHotel(trip);
    compensations.push(() => cancelHotel(hotelId));
    const carId = await rentCar(trip);
    compensations.push(() => cancelCar(carId));

    return `Booked: ${flightId}, ${hotelId}, ${carId}`;
  } catch (err) {
    // Compensate in reverse order
    for (const compensate of compensations.reverse()) {
      await compensate();
    }
    throw err;
  }
}
```

## Retry Policies

Configure on activities or child workflows. All fields optional with sensible defaults.
```typescript
retry: { // TypeScript
  initialInterval: '1s', backoffCoefficient: 2, maximumInterval: '30s',
  maximumAttempts: 5, nonRetryableErrorTypes: ['InvalidInputError'],
}
```
```go
// Go
RetryPolicy: &temporal.RetryPolicy{
    InitialInterval: time.Second, BackoffCoefficient: 2.0,
    MaximumInterval: 30 * time.Second, MaximumAttempts: 5,
    NonRetryableErrorTypes: []string{"InvalidInputError"},
}
```
```python
# Python
RetryPolicy(initial_interval=timedelta(seconds=1), backoff_coefficient=2.0,
            maximum_interval=timedelta(seconds=30), maximum_attempts=5,
            non_retryable_error_types=["InvalidInputError"])
```

## Versioning and Patching

Safely evolve workflow code while long-running workflows are in flight.
```typescript
// TypeScript — patched / deprecatePatch
export async function myWorkflow(): Promise<void> {
  if (wf.patched('new-logic-v2')) { await newActivity(); }
  else { await oldActivity(); }
}
// After all old workflows complete:
// wf.deprecatePatch('new-logic-v2'); await newActivity();
// Final cleanup: remove deprecatePatch call entirely.
```
```go
// Go — workflow.GetVersion
v := workflow.GetVersion(ctx, "new-logic-v2", workflow.DefaultVersion, 1)
if v == 1 { /* new code */ } else { /* old code */ }
```
```python
# Python — workflow.patched / workflow.deprecate_patch
if workflow.patched("new-logic-v2"): await new_activity()
else: await old_activity()
```

## Temporal CLI

### Development Server
```bash
temporal server start-dev                          # Start server + UI on localhost
temporal server start-dev --db-filename temporal.db # Persist data across restarts
temporal server start-dev --namespace custom-ns     # Custom namespace
```

### Workflow Operations
```bash
temporal workflow start --task-queue my-queue --type MyWorkflow --workflow-id wf-1 --input '"arg1"'
temporal workflow execute --task-queue my-queue --type MyWorkflow --input '"arg1"'  # Start + wait
temporal workflow describe --workflow-id wf-1
temporal workflow list
temporal workflow show --workflow-id wf-1           # Show event history
temporal workflow signal --workflow-id wf-1 --name approve --input '"yes"'
temporal workflow query --workflow-id wf-1 --type status
temporal workflow cancel --workflow-id wf-1
temporal workflow terminate --workflow-id wf-1 --reason "manual stop"
```

### Schedule Operations (Cron Replacement)
```bash
temporal schedule create --schedule-id daily-report \
  --interval '24h' \
  --task-queue reports --workflow-type DailyReport
temporal schedule list
temporal schedule describe --schedule-id daily-report
temporal schedule trigger --schedule-id daily-report  # Run immediately
temporal schedule delete --schedule-id daily-report
```

## Testing Workflows

All SDKs provide time-skipping test environments — `workflow.sleep('7 days')` resolves instantly.
```typescript
// TypeScript — TestWorkflowEnvironment
import { TestWorkflowEnvironment } from '@temporalio/testing';
const env = await TestWorkflowEnvironment.createTimeSkipping();
const worker = await Worker.create({
  connection: env.nativeConnection, workflowsPath: require.resolve('./workflows'),
  activities: { greet: async (name: string) => `Hi ${name}` }, taskQueue: 'test',
});
await worker.runUntil(async () => {
  const result = await env.client.workflow.execute('onboardUser', {
    args: ['Alice', 'a@b.com'], taskQueue: 'test', workflowId: 'test-1',
  });
  assert.equal(result, 'Hi Alice');
});
await env.teardown();
```

```go
// Go — testsuite.WorkflowTestSuite
env := (&testsuite.WorkflowTestSuite{}).NewTestWorkflowEnvironment()
env.RegisterActivity(ProcessOrder)
env.ExecuteWorkflow(OrderWorkflow, "order-1")
assert.True(t, env.IsWorkflowCompleted())
var result string
env.GetWorkflowResult(&result) // "processed-order-1"
```

```python
# Python — WorkflowEnvironment
async with await WorkflowEnvironment.start_time_skipping() as env:
    async with Worker(env.client, task_queue="test",
                      workflows=[PaymentWorkflow], activities=[charge_payment]):
        result = await env.client.execute_workflow(
            PaymentWorkflow.run, OrderInput("o-1", 50.0), id="test-1", task_queue="test")
        assert result == "charged-o-1-50.0"
```

## Schedules (Cron Replacement)

Modern replacement for cron workflows. Supports intervals, calendar specs, pausing, backfilling, overlap policies.
```typescript
const handle = await client.schedule.create({
  scheduleId: 'daily-cleanup',
  spec: { intervals: [{ every: '24h' }] },
  action: { type: 'startWorkflow', workflowType: 'cleanupWorkflow', taskQueue: 'maintenance' },
  policies: { overlap: 'SKIP' },  // SKIP, BUFFER_ONE, BUFFER_ALL, CANCEL_OTHER, TERMINATE_OTHER
});
await handle.pause('maintenance window');
await handle.unpause();
await handle.trigger();
```

## Visibility and Search Attributes

Search attributes enable filtering workflow executions via UI and CLI.
```bash
temporal operator search-attribute create --name CustomerId --type Keyword
temporal operator search-attribute create --name Priority --type Int
```
```typescript
// Set at start
const handle = await client.workflow.start('myWorkflow', {
  taskQueue: 'q', workflowId: 'wf-1',
  searchAttributes: { CustomerId: ['cust-123'], Priority: [5] },
});
// Upsert inside workflow
wf.upsertSearchAttributes({ Status: ['processing'] });
```
```bash
temporal workflow list --query 'CustomerId="cust-123" AND Status="processing"'
```

## Self-Hosted vs Temporal Cloud

Self-hosted: you operate the server, configure mTLS, connect at `localhost:7233`. Temporal Cloud: fully managed, built-in mTLS, connect at `<ns>.<acct>.tmprl.cloud:7233`, per-action pricing.
```typescript
const client = new Client({ // Cloud client
  namespace: 'my-ns.my-acct',
  connection: await Connection.connect({
    address: 'my-ns.my-acct.tmprl.cloud:7233',
    tls: { clientCertPair: { crt: cert, key: key } },
  }),
});
```

## Common Pitfalls

1. **Non-determinism in workflows** — `Date.now()`, `Math.random()`, `uuid()`, native timers, I/O in workflow code causes replay failures. Use SDK equivalents or delegate to activities.
2. **Activity code in workflow file** — TS workflow files run in a deterministic sandbox. Import activities only via `proxyActivities` with `type` imports.
3. **Missing timeouts** — Every activity must have at least `startToCloseTimeout` or `scheduleToCloseTimeout`.
4. **Unbounded history** — Use `continueAsNew` to reset history for long-running workflows. TS: `await continueAsNew<typeof myWorkflow>(newArgs)`. Go: `return workflow.NewContinueAsNewError(ctx, MyWorkflow, newArgs)`. Python: `raise workflow.ContinueAsNewError(arg=new_args)`.
5. **Confusing workflow ID and run ID** — Workflow ID is user-defined, unique per namespace. Run ID is system-generated.
6. **Not handling cancellation** — Use disconnected context for cleanup: `newCtx, _ := workflow.NewDisconnectedContext(ctx)` (Go).
7. **Deploying breaking changes** — Use versioning/patching APIs. Never change workflow logic for in-flight workflows without version guards.
8. **Starving task queues** — Ensure enough workers poll each queue. Monitor with `temporal task-queue describe`.

## References

- **[references/advanced-patterns.md](references/advanced-patterns.md)** — Saga, continue-as-new, child workflows, async completion, side effects, local activities, interceptors, search attributes, visibility API, multi-cluster replication, Nexus
- **[references/troubleshooting.md](references/troubleshooting.md)** — Non-determinism errors, timeouts, stuck workflows, history limits, worker tuning, memory, gRPC errors, namespace issues
- **[references/production-guide.md](references/production-guide.md)** — Docker Compose & K8s/Helm deployment, Temporal Cloud, Prometheus/Grafana, mTLS, encryption, archival, multi-tenancy, capacity planning

## Scripts (`./scripts/<name>.sh`)

- **[setup-dev.sh](scripts/setup-dev.sh)** — Start/stop local Temporal dev server with persistence
- **[scaffold-workflow.sh](scripts/scaffold-workflow.sh)** — Generate TypeScript or Go project scaffold
- **[diagnose.sh](scripts/diagnose.sh)** — Diagnose server health, task queues, failed/stuck workflows

## Assets

- **[docker-compose.yml](assets/docker-compose.yml)** — Temporal + PostgreSQL + Elasticsearch + Web UI
- **[workflow-template.ts](assets/workflow-template.ts)** — Workflow with signals, queries, saga, continueAsNew
- **[worker-template.ts](assets/worker-template.ts)** — Worker with mTLS, graceful shutdown, health check
- **[github-actions-ci.yml](assets/github-actions-ci.yml)** — CI: lint, type-check, unit/integration/replay tests
<!-- tested: pass -->
