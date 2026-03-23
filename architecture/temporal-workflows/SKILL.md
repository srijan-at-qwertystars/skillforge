---
name: temporal-workflows
description: |
  Use when user builds with Temporal, asks about workflow definitions, activities, signals, queries, child workflows, saga patterns, or durable execution with Temporal.
  Do NOT use for simple message queues (use message-queue-patterns skill), AWS Step Functions, or Apache Airflow DAGs.
---

# Temporal Workflow Orchestration

## Fundamentals

Temporal provides **durable execution** — workflow code runs as normal functions but survives process crashes, deployments, and infrastructure failures. The Temporal Server persists every state transition as an event history, enabling automatic replay and recovery.

**Core components:**
- **Workflow** — deterministic orchestration function. Survives failures via event replay. Never call external services directly.
- **Activity** — non-deterministic unit of work (API calls, DB writes, file I/O). Retried independently on failure.
- **Worker** — process that polls a task queue and executes workflows/activities. Deploy as stateless, horizontally scalable pools.
- **Task Queue** — named queue binding workflows/activities to workers. Use separate queues to isolate workloads and scale independently.
- **Temporal Server** — manages state, timers, and event history. Available as Temporal Cloud (managed) or self-hosted.

## Workflow Definitions

Workflow code must be **deterministic** — identical output on every replay. The server replays event history to reconstruct state.

**Rules for deterministic code:**
- Never use wall-clock time directly. Use `workflow.Now()` (Go) or Temporal's `sleep`/`timer` APIs.
- Never use random numbers directly. Use `workflow.SideEffect()` (Go) or `sideEffect()` (TS).
- Never spawn goroutines/threads outside Temporal APIs. Use `workflow.Go()` (Go) or Temporal's async primitives.
- Never access mutable global state or environment variables that change between replays.
- Never make network calls, read files, or perform I/O — delegate to activities.

### Versioning

Use versioning to evolve workflow logic without breaking running executions:

```go
// Go — patching
v := workflow.GetVersion(ctx, "add-notification-step", workflow.DefaultVersion, 1)
if v == 1 {
    err = workflow.ExecuteActivity(ctx, SendNotification, order).Get(ctx, nil)
}
```

```typescript
// TypeScript — patching
if (patched('add-notification-step')) {
  await sendNotification(order);
}
```

Always version before modifying logic that running workflows may replay through. Remove old version branches only after all executions on the old path complete.

### Side Effects

Capture non-deterministic values (UUIDs, timestamps) so replays return the recorded value:

```go
var uuid string
workflow.SideEffect(ctx, func(ctx workflow.Context) interface{} {
    return generateUUID()
}).Get(&uuid)
```

## Activities

Activities perform all non-deterministic work. Design them to be **idempotent**.

### Timeouts

Set all four timeout types:

| Timeout | Purpose |
|---|---|
| `ScheduleToClose` | Total time from scheduling to completion (end-to-end deadline) |
| `StartToClose` | Max time for a single attempt after worker picks it up |
| `ScheduleToStart` | Max time waiting in the task queue (detects worker unavailability) |
| `Heartbeat` | Interval for long-running activities to report progress |

```go
ao := workflow.ActivityOptions{
    StartToCloseTimeout:    5 * time.Minute,
    HeartbeatTimeout:       30 * time.Second,
    RetryPolicy: &temporal.RetryPolicy{
        InitialInterval:    time.Second,
        BackoffCoefficient: 2.0,
        MaximumInterval:    time.Minute,
        MaximumAttempts:    5,
        NonRetryableErrorTypes: []string{"InvalidInput"},
    },
}
ctx = workflow.WithActivityOptions(ctx, ao)
```

### Heartbeating

Long-running activities must heartbeat. Use heartbeat details to resume after retry:

```go
func ProcessLargeFile(ctx context.Context, fileURL string) error {
    var startOffset int
    if activity.HasHeartbeatDetails(ctx) {
        activity.GetHeartbeatDetails(ctx, &startOffset)
    }
    for i := startOffset; i < totalChunks; i++ {
        processChunk(i)
        activity.RecordHeartbeat(ctx, i)
    }
    return nil
}
```

### Cancellation

Respect cancellation by checking context:

```go
func LongActivity(ctx context.Context) error {
    for {
        select {
        case <-ctx.Done():
            cleanup()
            return ctx.Err()
        default:
            doWork()
        }
    }
}
```

## Signals and Queries

### Signals

Signals are asynchronous, fire-and-forget messages that mutate workflow state.

```typescript
// TypeScript — define and handle signal
const approvalSignal = wf.defineSignal<[boolean]>('approval');

export async function orderWorkflow(orderId: string): Promise<string> {
  let approved: boolean | undefined;
  wf.setHandler(approvalSignal, (value: boolean) => { approved = value; });

  await wf.condition(() => approved !== undefined, '24h');
  if (!approved) return 'rejected';
  await processOrder(orderId);
  return 'completed';
}
```

```go
// Go — receive signal
var approved bool
signalChan := workflow.GetSignalChannel(ctx, "approval")
signalChan.Receive(ctx, &approved)
```

### Queries

Queries are synchronous, read-only requests. Never mutate state in a query handler.

```typescript
const statusQuery = wf.defineQuery<string>('status');
wf.setHandler(statusQuery, () => currentStatus);
```

```go
err := workflow.SetQueryHandler(ctx, "status", func() (string, error) {
    return currentStatus, nil
})
```

### Updates

Updates combine signal mutation with query synchronous response:

```typescript
const updatePrice = wf.defineUpdate<number, [number]>('updatePrice');
wf.setHandler(updatePrice, (newPrice: number) => {
  price = newPrice;
  return price;
}, { validator: (p: number) => { if (p < 0) throw new Error('Must be positive'); } });
```

Ensure handlers are registered early — signals/updates can arrive before the main workflow body executes (e.g., signal-with-start).

## Child Workflows

Use child workflows to decompose complex logic, enforce separate retry policies, or continue-as-new independently.

**Parent close policies:**
- `TERMINATE` — cancel child when parent completes (default).
- `ABANDON` — child continues running independently.
- `REQUEST_CANCEL` — send cancellation request to child.

### Continue-As-New

Use `ContinueAsNew` to reset event history for long-running workflows. Prevents unbounded history growth:

```go
func RecurringWorkflow(ctx workflow.Context, iteration int) error {
    doWork(ctx)
    return workflow.NewContinueAsNewError(ctx, RecurringWorkflow, iteration+1)
}
```

```typescript
export async function recurringWorkflow(iteration: number): Promise<void> {
  await doWork();
  await wf.continueAsNew<typeof recurringWorkflow>(iteration + 1);
}
```

## Error Handling

### Retry Policies

Configure retries at the activity level. Workflow-level retries are rarely needed.

```go
retryPolicy := &temporal.RetryPolicy{
    InitialInterval:        time.Second,
    BackoffCoefficient:     2.0,
    MaximumInterval:        5 * time.Minute,
    MaximumAttempts:        0, // unlimited retries until timeout
    NonRetryableErrorTypes: []string{"InvalidInput", "NotFound"},
}
```

### Non-Retryable Errors

Mark errors as non-retryable to fail fast on permanent failures:

### Workflow Failure

Workflows fail when they return an error or throw an unhandled exception. Catch activity errors to decide whether to compensate or fail.

## Saga Pattern

Implement compensating transactions for multi-step distributed operations:

```typescript
export async function bookTripSaga(trip: TripDetails): Promise<string> {
  const compensations: Array<() => Promise<void>> = [];
  try {
    const flightId = await bookFlight(trip.flight);
    compensations.push(() => cancelFlight(flightId));

    const hotelId = await bookHotel(trip.hotel);
    compensations.push(() => cancelHotel(hotelId));

    const carId = await bookCar(trip.car);
    compensations.push(() => cancelCar(carId));

    return `booked: ${flightId}, ${hotelId}, ${carId}`;
  } catch (err) {
    for (const compensate of compensations.reverse()) {
      await compensate();
    }
    throw err;
  }
}
```

```go
func BookTripSaga(ctx workflow.Context, trip TripDetails) (string, error) {
    var compensations []func(workflow.Context) error

    flightID, err := bookFlight(ctx, trip.Flight)
    if err != nil { return "", err }
    compensations = append(compensations, func(ctx workflow.Context) error {
        return cancelFlight(ctx, flightID)
    })

    hotelID, err := bookHotel(ctx, trip.Hotel)
    if err != nil {
        runCompensations(ctx, compensations)
        return "", err
    }
    compensations = append(compensations, func(ctx workflow.Context) error {
        return cancelHotel(ctx, hotelID)
    })

    return fmt.Sprintf("booked: %s, %s", flightID, hotelID), nil
}

func runCompensations(ctx workflow.Context, comps []func(workflow.Context) error) {
    for i := len(comps) - 1; i >= 0; i-- {
        if err := comps[i](ctx); err != nil {
            workflow.GetLogger(ctx).Error("compensation failed", "error", err)
        }
    }
}
```

Run compensation activities with generous retry policies — compensations must succeed.

## Timers and Scheduling

Use `workflow.Sleep` (Go) / `wf.sleep('24h')` (TS) for durable timers that survive restarts.

Set cron schedules on workflow options, but prefer **Schedules** (Temporal's native scheduling API) for new code — they support backfill, pause/resume, and overlap policies.

Set `ScheduleToClose` timeout as the hard deadline for activity completion across all retries.

## TypeScript SDK

### Worker Setup

```typescript
import { Worker } from '@temporalio/worker';
import * as activities from './activities';

const worker = await Worker.create({
  workflowsPath: require.resolve('./workflows'),
  activities,
  taskQueue: 'main-queue',
  maxConcurrentActivityTaskExecutions: 100,
  maxConcurrentWorkflowTaskExecutions: 50,
});
await worker.run();
```

### Client

```typescript
import { Client } from '@temporalio/client';

const client = new Client();
const handle = await client.workflow.start(orderWorkflow, {
  taskQueue: 'main-queue',
  workflowId: `order-${orderId}`,
  args: [orderId],
});
const result = await handle.result();
```

Use deterministic workflow IDs (e.g., entity-based) to prevent duplicate executions.

## Go SDK

### Worker Setup

```go
c, _ := client.Dial(client.Options{})
w := worker.New(c, "main-queue", worker.Options{
    MaxConcurrentActivityExecutionSize:     100,
    MaxConcurrentWorkflowTaskExecutionSize: 50,
})
w.RegisterWorkflow(OrderWorkflow)
w.RegisterActivity(ProcessPayment)
w.Run(worker.InterruptCh())
```

### Context Propagation

Pass trace context through workflows and activities using interceptors and context propagators:

```go
c, _ := client.Dial(client.Options{
    ContextPropagators: []workflow.ContextPropagator{
        tracing.NewContextPropagator(),
    },
})
```

## Python SDK

### Workflow and Activity

```python
from temporalio import workflow, activity
from temporalio.client import Client
from temporalio.worker import Worker
from datetime import timedelta

@activity.defn
async def process_order(order_id: str) -> str:
    # non-deterministic work here
    return f"processed-{order_id}"

@workflow.defn
class OrderWorkflow:
    @workflow.run
    async def run(self, order_id: str) -> str:
        return await workflow.execute_activity(
            process_order,
            order_id,
            start_to_close_timeout=timedelta(minutes=5),
        )

async def main():
    client = await Client.connect("localhost:7233")
    worker = Worker(
        client, task_queue="main-queue",
        workflows=[OrderWorkflow],
        activities=[process_order],
    )
    await worker.run()
```

Use `@workflow.signal`, `@workflow.query`, and `@workflow.update` decorators for message handlers.

## Testing

### Workflow Test Environment

Use SDK-provided test environments with time skipping for long-running workflows:

```typescript
import { TestWorkflowEnvironment } from '@temporalio/testing';
import { orderWorkflow } from './workflows';

const env = await TestWorkflowEnvironment.createTimeSkipping();
const handle = await env.client.workflow.start(orderWorkflow, {
  taskQueue: 'test-queue',
  workflowId: 'test-order-1',
  args: ['order-123'],
});
const result = await handle.result();
```

### Mocking Activities

```go
s := testsuite.WorkflowTestSuite{}
env := s.NewTestWorkflowEnvironment()
env.RegisterWorkflow(OrderWorkflow)
env.OnActivity(ProcessPayment, mock.Anything, mock.Anything).Return("payment-ok", nil)
env.ExecuteWorkflow(OrderWorkflow, "order-123")
assert.True(t, env.IsWorkflowCompleted())
```

Test signal/query handlers by sending signals and queries through the test environment.

## Deployment

### Temporal Cloud

- Use distinct **namespaces** per environment (dev, staging, prod).
- Configure **mTLS** certificates for worker authentication.
- Set **retention period** per namespace (default 7 days). Use **multi-region** namespaces for HA.

### Self-Hosted

- Deploy Temporal Server with PostgreSQL or Cassandra. Use Helm charts for Kubernetes.
- Run Temporal Web UI for visibility. Configure Elasticsearch for advanced search.

### Namespace Management

```bash
temporal operator namespace create --namespace prod-orders --retention 30d
```

## Observability

### Metrics

Expose Prometheus metrics from workers. Key metrics: `temporal_workflow_task_execution_latency`, `temporal_activity_execution_latency`, `temporal_workflow_endtoend_latency`, `temporal_sticky_cache_hit`.

### Search Attributes

Add custom search attributes for filtering workflows in the UI and API:

```go
workflow.UpsertSearchAttributes(ctx, map[string]interface{}{
    "CustomerId": customerId,
    "OrderTotal": total,
})
```

```typescript
wf.upsertSearchAttributes({ CustomerId: [customerId], OrderTotal: [total] });
```

### Tracing

Use OpenTelemetry interceptors for distributed tracing. Temporal SDKs provide built-in interceptor support.

## Anti-Patterns

| Anti-Pattern | Problem | Fix |
|---|---|---|
| Non-deterministic workflow code | Replay failures, non-determinism errors | Move I/O to activities; use `SideEffect` for randomness/time |
| Large payloads (>2MB) | Event history bloat, slow replays | Store data externally (S3, DB); pass references |
| Unbounded loops without continue-as-new | Unbounded event history growth | Call `ContinueAsNew` after N iterations or periodic intervals |
| Missing versioning on workflow changes | Breaks running executions on deploy | Always use `GetVersion`/`patched` before modifying replayed logic |
| Blocking calls in workflow code | Deadlocks, non-determinism | Use only Temporal async APIs (`workflow.Sleep`, `workflow.Go`) |
| No heartbeat on long activities | Activities not detected as failed until timeout | Add `RecordHeartbeat` with progress details |
| Ignoring cancellation context | Resource leaks, zombie activities | Check `ctx.Done()` and clean up |
| Hardcoded timeouts | Fragile under load | Make timeouts configurable; use appropriate timeout types |
| Sharing mutable state across handlers | Race conditions during replay | Use workflow-local state; process signals sequentially |
| Workflow doing too much | Long histories, complex replay | Decompose into child workflows or use continue-as-new |

<!-- tested: pass -->
