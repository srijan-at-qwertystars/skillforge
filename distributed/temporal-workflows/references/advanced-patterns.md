# Temporal Advanced Patterns

## Table of Contents

- [Saga Pattern Implementation](#saga-pattern-implementation)
- [Long-Running Workflows](#long-running-workflows-monthsyears)
- [Continue-As-New](#continue-as-new)
- [Child Workflow Patterns](#child-workflow-patterns)
- [Async Completion](#async-completion)
- [Side Effects](#side-effects)
- [Local Activities](#local-activities)
- [Workflow Interceptors](#workflow-interceptors)
- [Custom Search Attributes](#custom-search-attributes)
- [Visibility API](#visibility-api)
- [Multi-Cluster Replication](#multi-cluster-replication)
- [Nexus Operations](#nexus-operations)

---

## Saga Pattern Implementation

The saga pattern manages distributed transactions by executing a sequence of steps with compensating actions for rollback. Temporal makes this trivial compared to event-driven sagas because the orchestration logic is plain code.

### Production-Grade Saga (TypeScript)

```typescript
interface SagaStep<T> {
  action: () => Promise<T>;
  compensation: (result: T) => Promise<void>;
  name: string;
}

export async function sagaOrchestrator<T>(steps: SagaStep<T>[]): Promise<T[]> {
  const completedSteps: { result: T; compensation: (r: T) => Promise<void> }[] = [];

  try {
    for (const step of steps) {
      const result = await step.action();
      completedSteps.push({ result, compensation: step.compensation });
    }
    return completedSteps.map(s => s.result);
  } catch (err) {
    // Compensate in reverse order — each compensation is itself retried by Temporal
    for (const step of completedSteps.reverse()) {
      try {
        await step.compensation(step.result);
      } catch (compErr) {
        // Log but continue compensating remaining steps
        log.error('Compensation failed', { error: compErr });
      }
    }
    throw err;
  }
}
```

### Parallel Saga with Partial Failure

```typescript
export async function parallelSaga(orders: OrderInput[]): Promise<string[]> {
  const compensations: Array<() => Promise<void>> = [];
  const results: string[] = [];

  // Fan-out: run independent steps in parallel
  const settled = await Promise.allSettled(
    orders.map(async (order) => {
      const id = await reserveInventory(order);
      compensations.push(() => releaseInventory(id));
      return id;
    })
  );

  // If any failed, compensate all successful ones
  const failures = settled.filter(r => r.status === 'rejected');
  if (failures.length > 0) {
    for (const comp of compensations.reverse()) { await comp(); }
    throw ApplicationFailure.create({ message: 'Partial reservation failure' });
  }

  return settled.map(r => (r as PromiseFulfilledResult<string>).value);
}
```

### Go Saga Pattern

```go
type SagaStep struct {
    Action       func(ctx workflow.Context) (interface{}, error)
    Compensate   func(ctx workflow.Context, result interface{}) error
}

func RunSaga(ctx workflow.Context, steps []SagaStep) ([]interface{}, error) {
    var completed []struct {
        result     interface{}
        compensate func(workflow.Context, interface{}) error
    }

    for _, step := range steps {
        result, err := step.Action(ctx)
        if err != nil {
            // Run compensations in reverse using disconnected context
            compCtx, _ := workflow.NewDisconnectedContext(ctx)
            for i := len(completed) - 1; i >= 0; i-- {
                _ = completed[i].compensate(compCtx, completed[i].result)
            }
            return nil, err
        }
        completed = append(completed, struct {
            result     interface{}
            compensate func(workflow.Context, interface{}) error
        }{result, step.Compensate})
    }
    results := make([]interface{}, len(completed))
    for i, c := range completed { results[i] = c.result }
    return results, nil
}
```

**Key insight**: Use `workflow.NewDisconnectedContext(ctx)` in Go for compensations so they execute even if the parent context is cancelled.

---

## Long-Running Workflows (Months/Years)

Workflows can run for months or years. Critical considerations:

1. **History size**: Default warn limit is 10,240 events, hard error at 51,200. Use `continueAsNew` before hitting limits.
2. **Versioning**: Long-lived workflows will span multiple code deployments. Always use patching/versioning APIs.
3. **Heartbeating**: Long-running activities must heartbeat to avoid timeout and enable progress tracking.
4. **Idempotency**: Activities may be retried — ensure external operations are idempotent.

### Entity Workflow Pattern (TypeScript)

An entity workflow processes signals/updates over a long lifecycle, using `continueAsNew` to reset history:

```typescript
export async function subscriptionWorkflow(state: SubscriptionState): Promise<void> {
  let eventCount = 0;
  const MAX_EVENTS_BEFORE_CAN = 500;

  wf.setHandler(renewSignal, () => { state.renewedAt = Date.now(); eventCount++; });
  wf.setHandler(cancelSignal, () => { state.status = 'cancelled'; eventCount++; });
  wf.setHandler(statusQuery, () => state);

  while (state.status === 'active') {
    if (eventCount >= MAX_EVENTS_BEFORE_CAN) {
      await continueAsNew<typeof subscriptionWorkflow>(state);
    }
    const renewed = await wf.condition(() => state.status !== 'active', '30 days');
    if (!renewed) {
      await chargeSubscription(state);
      eventCount++;
    }
  }

  await handleCancellation(state);
}
```

---

## Continue-As-New

Prevents unbounded history growth. The workflow completes and immediately starts a new execution with fresh history, carrying over state as arguments.

### When to Use
- Polling workflows (check external state periodically)
- Entity workflows processing many signals
- Batch processing with large iteration counts
- Any workflow accumulating >5,000 events

### TypeScript
```typescript
import { continueAsNew } from '@temporalio/workflow';

export async function pollingWorkflow(cursor: string, iteration: number): Promise<void> {
  const result = await checkExternalSystem(cursor);

  if (result.done) return;

  if (iteration > 100) {
    await continueAsNew<typeof pollingWorkflow>(result.nextCursor, 0);
  }

  await sleep('1 minute');
  await continueAsNew<typeof pollingWorkflow>(result.nextCursor, iteration + 1);
}
```

### Go
```go
func PollingWorkflow(ctx workflow.Context, cursor string, iteration int) error {
    result, err := executeCheckActivity(ctx, cursor)
    if err != nil { return err }
    if result.Done { return nil }

    if iteration > 100 {
        return workflow.NewContinueAsNewError(ctx, PollingWorkflow, result.NextCursor, 0)
    }

    _ = workflow.Sleep(ctx, time.Minute)
    return workflow.NewContinueAsNewError(ctx, PollingWorkflow, result.NextCursor, iteration+1)
}
```

**Important**: Search attributes, memos, and retry policies carry over by default. Signal handlers are re-registered on the new run.

---

## Child Workflow Patterns

### Fan-Out / Fan-In

```typescript
export async function batchProcessor(items: string[]): Promise<Result[]> {
  const BATCH_SIZE = 10;
  const results: Result[] = [];

  for (let i = 0; i < items.length; i += BATCH_SIZE) {
    const batch = items.slice(i, i + BATCH_SIZE);
    const batchResults = await Promise.all(
      batch.map((item, idx) =>
        executeChild(processItemWorkflow, {
          args: [item],
          workflowId: `batch-${i + idx}-${item}`,
        })
      )
    );
    results.push(...batchResults);
  }
  return results;
}
```

### Parent-Child Cancellation Policies

```typescript
const handle = await startChild(childWorkflow, {
  args: [data],
  workflowId: `child-${id}`,
  parentClosePolicy: ParentClosePolicy.TERMINATE,    // Also: REQUEST_CANCEL, ABANDON
  cancellationType: ChildWorkflowCancellationType.WAIT_CANCELLATION_COMPLETED,
});
```

- `TERMINATE`: Child is terminated when parent closes
- `REQUEST_CANCEL`: Child receives cancellation request (can do cleanup)
- `ABANDON`: Child continues independently

### Nested Child Workflows (Go)

```go
// Rate-limited child spawning
func BatchParent(ctx workflow.Context, items []string) error {
    sem := workflow.NewSemaphore(ctx, 5) // Max 5 concurrent children
    for _, item := range items {
        _ = sem.Acquire(ctx, 1)
        workflow.Go(ctx, func(gCtx workflow.Context) {
            defer sem.Release(1)
            cwo := workflow.ChildWorkflowOptions{WorkflowID: "child-" + item}
            gCtx = workflow.WithChildOptions(gCtx, cwo)
            _ = workflow.ExecuteChildWorkflow(gCtx, ProcessItem, item).Get(gCtx, nil)
        })
    }
    // Wait for all to complete
    _ = sem.Acquire(ctx, 5)
    return nil
}
```

---

## Async Completion

Activities that need external human/system input before completing. The activity starts, returns a task token, and is later completed externally.

### TypeScript

```typescript
// Activity — raises to indicate async completion
export async function requestApproval(request: ApprovalRequest): Promise<string> {
  const info = Context.current().info;
  const taskToken = info.taskToken;

  // Send task token to external system (e.g., Slack, email)
  await notifyApprover(request, Buffer.from(taskToken).toString('base64'));

  // This tells Temporal the activity is not done yet
  Context.current().heartbeat();
  throw new CompleteAsyncError();
}

// External service completes the activity
const client = new Client();
await client.activity.complete(taskToken, 'approved');
// Or fail it:
await client.activity.fail(taskToken, new Error('rejected'));
```

### Go

```go
func RequestApproval(ctx context.Context, req ApprovalRequest) (string, error) {
    info := activity.GetInfo(ctx)
    sendToApprover(req, info.TaskToken)
    return "", activity.ErrResultPending // Signals async completion
}

// External completion
client.CompleteActivity(ctx, taskToken, "approved", nil)
```

---

## Side Effects

Record non-deterministic values (random numbers, UUIDs, timestamps) in workflow history so replays produce identical results.

```typescript
// TypeScript — returns same value on replay
const randomValue = await wf.sideEffect(() => Math.random());
const uuid = await wf.sideEffect(() => crypto.randomUUID());
```

```go
// Go
var uuid string
_ = workflow.SideEffect(ctx, func(ctx workflow.Context) interface{} {
    return generateUUID()
}).Get(&uuid)
```

**Rules**: Side effects must return serializable values, should be short/cheap, and must never fail. For fallible operations, use activities instead.

---

## Local Activities

Execute short-lived activities in the same worker process without scheduling via the server. Saves a round-trip.

```typescript
const { lookupCache } = wf.proxyLocalActivities<typeof activities>({
  startToCloseTimeout: '5s',
  // Local activities do not survive worker restart — keep them short
});

export async function myWorkflow(key: string): Promise<string> {
  const cached = await lookupCache(key); // Runs in-process, no server round-trip
  if (cached) return cached;
  return await fetchFromDB(key); // Regular activity for durable work
}
```

**When to use**: In-memory lookups, input validation, data transformation, short computations (<5s). **When NOT to use**: Network calls, database writes, anything that must survive worker crashes.

---

## Workflow Interceptors

Cross-cutting concerns (logging, tracing, auth, metrics) without modifying business logic.

### TypeScript Worker Interceptor

```typescript
import { WorkflowInterceptorsFactory } from '@temporalio/workflow';

export const interceptors: WorkflowInterceptorsFactory = () => ({
  inbound: [
    {
      async execute(input, next) {
        log.info('Workflow started', { workflowType: input.headers });
        const result = await next(input);
        log.info('Workflow completed');
        return result;
      },
      async handleSignal(input, next) {
        log.info('Signal received', { signalName: input.signalName });
        return next(input);
      },
    },
  ],
  outbound: [
    {
      async scheduleActivity(input, next) {
        log.info('Scheduling activity', { activityType: input.activityType });
        return next(input);
      },
    },
  ],
});

// Register in worker
const worker = await Worker.create({
  workflowsPath: require.resolve('./workflows'),
  interceptors: { workflowModules: [require.resolve('./interceptors')] },
  activities,
  taskQueue: 'my-queue',
});
```

### Common Interceptor Uses
- **OpenTelemetry tracing**: Propagate trace context across workflow/activity boundaries
- **Authorization**: Validate caller identity from headers before workflow execution
- **Metrics**: Record workflow/activity duration, success/failure counts
- **Payload encryption**: Encrypt/decrypt payloads transparently

---

## Custom Search Attributes

Index workflow metadata for filtering in the UI, CLI, and programmatic queries.

### Supported Types
| Type | Example Values |
|------|---------------|
| Keyword | `"order-123"`, `"us-east-1"` |
| Text | Full-text searchable strings |
| Int | `42`, `100` |
| Double | `3.14`, `99.99` |
| Bool | `true`, `false` |
| Datetime | `"2024-01-15T10:30:00Z"` |
| KeywordList | `["tag1", "tag2"]` |

### Registration and Usage

```bash
# Register custom search attributes
temporal operator search-attribute create --name CustomerId --type Keyword
temporal operator search-attribute create --name OrderTotal --type Double
temporal operator search-attribute create --name Region --type Keyword
temporal operator search-attribute create --name IsHighPriority --type Bool
```

```typescript
// Set at workflow start
await client.workflow.start('orderWorkflow', {
  taskQueue: 'orders',
  workflowId: 'order-123',
  searchAttributes: {
    CustomerId: ['cust-456'],
    OrderTotal: [299.99],
    Region: ['us-east-1'],
    IsHighPriority: [true],
  },
});

// Update inside workflow
wf.upsertSearchAttributes({ OrderStatus: ['shipped'], Region: ['us-west-2'] });
```

**Limits**: Max 100 custom search attributes per namespace. Keyword values max 256 chars.

---

## Visibility API

Query workflow executions programmatically using SQL-like list filters.

```typescript
const client = new Client();

// List with filter
const workflows = client.workflow.list({
  query: `CustomerId = "cust-456" AND ExecutionStatus = "Running" ORDER BY StartTime DESC`,
});

for await (const wf of workflows) {
  console.log(wf.workflowId, wf.status.name, wf.searchAttributes);
}

// Count workflows
const count = await client.workflow.count({
  query: 'ExecutionStatus = "Running" AND TaskQueue = "orders"',
});
```

```bash
# CLI queries
temporal workflow list --query 'ExecutionStatus="Running" AND CustomerId="cust-456"'
temporal workflow list --query 'StartTime > "2024-01-01T00:00:00Z"' --limit 50
temporal workflow count --query 'ExecutionStatus="Failed"'
```

---

## Multi-Cluster Replication

Provides disaster recovery by asynchronously replicating workflow executions across clusters. **Status**: Experimental feature.

### Key Concepts
- **Active/Standby**: Each namespace has one active cluster; others are standby
- **Asynchronous replication**: Standby clusters lag behind active by seconds/minutes
- **Automatic forwarding**: Start, signal, and query requests to standby are forwarded to active
- **Failover**: Promote standby to active via admin API; all pending work resumes

### Configuration (self-hosted)

```yaml
# temporal-server config
clusterMetadata:
  enableGlobalNamespace: true
  failoverVersionIncrement: 10
  masterClusterName: "cluster-east"
  currentClusterName: "cluster-east"
  clusterInformation:
    cluster-east:
      enabled: true
      initialFailoverVersion: 1
      rpcAddress: "east.temporal.internal:7233"
    cluster-west:
      enabled: true
      initialFailoverVersion: 2
      rpcAddress: "west.temporal.internal:7233"
```

### Failover

```bash
temporal operator namespace update --namespace prod \
  --active-cluster cluster-west
```

---

## Nexus Operations

Nexus enables cross-namespace and cross-cluster service invocation with a unified API. Available in Temporal v1.26+.

### Concepts
- **Nexus Service**: A named collection of operations exposed by a worker
- **Nexus Endpoint**: A reverse proxy registered in the Nexus Registry, routing requests to workers
- **Sync Operations**: Execute inline, return immediately
- **Async Operations**: Return an operation ID, support polling, callbacks, and cancellation

### TypeScript — Defining a Nexus Service

```typescript
import { nexus } from '@temporalio/workflow';

const myService = nexus.defineService({
  name: 'payment-service',
  operations: {
    charge: nexus.defineOperation<ChargeInput, ChargeResult>({
      async handler(input) {
        return await chargePayment(input);
      },
    }),
    refund: nexus.defineOperation<RefundInput, RefundResult>({
      async start(input, options) {
        // Start async workflow-backed operation
        const handle = await startChild(refundWorkflow, { args: [input] });
        return nexus.asyncOperationResult(handle.workflowId);
      },
    }),
  },
});
```

### Calling Nexus Operations from a Workflow

```typescript
const paymentService = wf.createNexusClient<typeof paymentServiceDef>({
  endpoint: 'payment-endpoint',
  service: 'payment-service',
});

export async function orderWorkflow(order: Order): Promise<void> {
  const chargeResult = await paymentService.charge({ amount: order.total });
  // Async operation — Temporal handles polling/completion
  const refundResult = await paymentService.refund({ chargeId: chargeResult.id });
}
```

### Registering Endpoints

```bash
# Self-hosted
temporal operator nexus endpoint create \
  --name payment-endpoint \
  --target-namespace payments-ns \
  --target-task-queue payment-workers

# Temporal Cloud — via UI or tcld CLI
tcld nexus endpoint create --name payment-endpoint ...
```

**Use cases**: Multi-team boundaries, cross-namespace orchestration, gradual migration between namespaces, polyglot service composition.
