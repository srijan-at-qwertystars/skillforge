# Temporal Troubleshooting Guide

## Table of Contents

- [Non-Determinism Errors](#non-determinism-errors)
- [Workflow Task Timeout](#workflow-task-timeout)
- [Activity Timeout Tuning](#activity-timeout-tuning)
- [Stuck Workflows](#stuck-workflows)
- [History Size Limits](#history-size-limits)
- [Worker Tuning](#worker-tuning)
- [Memory Issues](#memory-issues)
- [gRPC Errors](#grpc-errors)
- [Namespace Configuration Problems](#namespace-configuration-problems)
- [Diagnostic Commands Cheat Sheet](#diagnostic-commands-cheat-sheet)

---

## Non-Determinism Errors

Non-determinism is the #1 source of Temporal bugs. It occurs when replayed workflow code produces different commands than what's recorded in history.

### Error Message

```
Nondeterminism error: [TMPRL1100] query handler made a non-deterministic change
Workflow task error: NonDeterministicError
```

### Common Causes

| Cause | Example | Fix |
|-------|---------|-----|
| Using system time | `Date.now()`, `time.Now()` | Use `workflow.Now()` (Go) or SDK time utils |
| Random values | `Math.random()`, `uuid.v4()` | Use `workflow.SideEffect` or activities |
| Non-deterministic iteration | Go `range map` | Sort map keys before iterating |
| Conditional on external state | Reading env vars, config files | Pass configuration as workflow arguments |
| Changing workflow logic | Removing/reordering activities | Use patching/versioning APIs |
| Adding new signals/queries | Adding handlers in deployed workflow | Use versioning to add new handlers |
| Third-party library updates | Library uses `Math.random` internally | Audit dependencies; sandbox catches in TS |
| Native async/concurrency | `goroutine` without `workflow.Go` | Use SDK-provided concurrency primitives |

### Prevention

1. **Replay testing** — Fetch production workflow histories and replay them against new code before deploying:
   ```bash
   # Export workflow history
   temporal workflow show --workflow-id my-wf --output json > history.json
   ```
   ```typescript
   // Replay test (TypeScript)
   import { Worker } from '@temporalio/worker';
   const result = await Worker.runReplayHistory(
     { workflowsPath: require.resolve('./workflows') },
     history
   );
   ```
   ```go
   // Replay test (Go)
   replayer := worker.NewWorkflowReplayer()
   replayer.RegisterWorkflow(MyWorkflow)
   err := replayer.ReplayWorkflowHistoryFromJSONFile(nil, "history.json")
   ```

2. **Static analysis (Go)** — Use the `workflowcheck` tool:
   ```bash
   go install go.temporal.io/sdk/contrib/tools/workflowcheck@latest
   workflowcheck ./...
   ```

3. **TypeScript sandbox** — The TS SDK runs workflow code in a deterministic sandbox that blocks `Date`, `Math.random`, etc. Do NOT disable the sandbox in production.

### Recovery

If a workflow is already stuck due to non-determinism:

```bash
# Reset to last good workflow task
temporal workflow reset --workflow-id my-wf --type LastWorkflowTask --reason "fix non-determinism"

# Reset to a specific event ID
temporal workflow reset --workflow-id my-wf --event-id 42 --reason "reset to before change"

# For batch reset of many affected workflows
temporal workflow reset --query 'TaskQueue="my-queue" AND ExecutionStatus="Running"' \
  --type LastWorkflowTask --reason "deploy fix"
```

---

## Workflow Task Timeout

Workflow tasks have a default timeout of 10 seconds (max 2 minutes). A workflow task is one "turn" of deterministic replay + new command generation.

### Symptoms
- Workflow appears stuck, then retries from the beginning
- Event history shows `WorkflowTaskTimedOut` events
- Worker logs show repeated replay of the same workflow

### Common Causes

1. **Expensive replay**: Workflow with large history takes >10s to replay
   - Fix: Use `continueAsNew` to keep history under 5,000 events
2. **Deadlock in workflow code**: Infinite loop or blocking operation
   - Fix: Use the deadlock detector; check for `while(true)` without `await`
3. **Large payloads**: Deserializing huge activity results during replay
   - Fix: Store large data externally; pass references (S3 URLs, DB IDs)
4. **Too many concurrent workflows on one worker**: Replay contention
   - Fix: Increase worker count or reduce `maxConcurrentWorkflowTaskExecutions`
5. **Cache eviction**: Sticky execution cache too small, causing full replay every task
   - Fix: Increase `maxCachedWorkflows` (default 600 for TS)

### Tuning

```typescript
// TypeScript worker
const worker = await Worker.create({
  // ...
  maxCachedWorkflows: 1000,        // Sticky cache size (default: 600)
  maxConcurrentWorkflowTaskExecutions: 40,  // Default: 40
});
```

```go
// Go worker
w := worker.New(c, "queue", worker.Options{
    StickyScheduleToStartTimeout: 5 * time.Second,  // Default: 5s
    WorkflowPanicPolicy: worker.FailWorkflow,
})
```

---

## Activity Timeout Tuning

### Timeout Hierarchy

```
ScheduleToCloseTimeout (total time including all retries)
├── ScheduleToStartTimeout (time in queue waiting for a worker)
└── StartToCloseTimeout (time for a single attempt)

HeartbeatTimeout (must heartbeat within this interval)
```

### Tuning Guidelines

| Activity Type | StartToClose | ScheduleToClose | Heartbeat | Retries |
|--------------|-------------|-----------------|-----------|---------|
| Fast API call | 5-30s | 2-5min | — | 3-5 |
| Database query | 10-60s | 5min | — | 3 |
| File processing | 5-30min | 2h | 30-60s | 2-3 |
| ML model training | 1-6h | 24h | 5min | 1-2 |
| Human approval | — | 7 days | — | 1 |
| Batch ETL job | 2h | 12h | 2min | 2 |

### Common Mistakes

1. **Only setting ScheduleToClose**: Individual attempts can run forever. Always set `StartToCloseTimeout` too.
2. **No heartbeat on long activities**: If a worker crashes mid-activity, Temporal won't know until `StartToCloseTimeout` expires. Use `HeartbeatTimeout` for activities >30s.
3. **HeartbeatTimeout too short**: Set to 2-3x your expected heartbeat interval to allow for GC pauses and load spikes.
4. **Forgetting ScheduleToStart**: Detect task queue starvation by setting `ScheduleToStartTimeout` (5-10min typical).

### Heartbeat with Progress

```typescript
export async function processBatch(items: string[]): Promise<number> {
  // Resume from last heartbeat on retry
  const startIdx: number = Context.current().info.heartbeatDetails ?? 0;

  for (let i = startIdx; i < items.length; i++) {
    await processItem(items[i]);
    Context.current().heartbeat(i + 1); // Record progress
  }
  return items.length;
}
```

---

## Stuck Workflows

A workflow that stops making progress. Diagnosis depends on where it's stuck.

### Diagnostic Flowchart

```
Workflow not progressing
├─ Check: Is a worker running for this task queue?
│  └─ No → Start/deploy a worker polling the correct task queue
├─ Check: WorkflowTaskTimedOut in history?
│  └─ Yes → See "Workflow Task Timeout" section
├─ Check: Activity stuck (no completion event)?
│  ├─ ActivityTaskTimedOut → Activity failing all retries. Check activity logs.
│  ├─ No worker for activity task queue → Deploy activity worker
│  └─ Long running without heartbeat → Activity worker may have crashed
├─ Check: Waiting on signal/condition?
│  └─ Send the expected signal or check signal sender
├─ Check: Waiting on child workflow?
│  └─ Debug the child workflow (recursive check)
└─ Check: Timer (workflow.sleep)?
   └─ Timer hasn't elapsed yet — expected behavior
```

### Quick Diagnosis Commands

```bash
# Check workflow status and pending activities
temporal workflow describe --workflow-id my-wf

# View full event history
temporal workflow show --workflow-id my-wf

# Check task queue — are workers polling?
temporal task-queue describe --task-queue my-queue

# List pending activities (look for ScheduledTimestamp vs now)
temporal workflow show --workflow-id my-wf | grep -A5 "ActivityTaskScheduled"

# Check for failed workflow tasks
temporal workflow show --workflow-id my-wf | grep "WorkflowTaskFailed"
```

### Unsticking a Workflow

```bash
# Send a missing signal
temporal workflow signal --workflow-id my-wf --name mySignal --input '"value"'

# Reset to retry from a specific point
temporal workflow reset --workflow-id my-wf --type LastWorkflowTask --reason "unstick"

# Nuclear option: terminate and restart
temporal workflow terminate --workflow-id my-wf --reason "stuck, restarting"
temporal workflow start --task-queue my-queue --type MyWorkflow --workflow-id my-wf-v2
```

---

## History Size Limits

| Metric | Warn Threshold | Hard Limit |
|--------|---------------|------------|
| Event count | 10,240 events | 51,200 events |
| History size | 10 MiB | 50 MiB |

When the warn threshold is reached, Temporal emits a warning and the SDK will attempt to `continueAsNew`. At the hard limit, the workflow is terminated.

### Reducing History Size

1. **Use continueAsNew**: The primary solution. Carry over minimal state.
2. **Child workflows**: Offload batches/loops to children (each has independent history).
3. **Minimize signal frequency**: Batch multiple signals if possible.
4. **Reduce activity results**: Return IDs/references, not full data.
5. **Compress payloads**: Use a codec in the data converter.

### Monitoring History Growth

```bash
# Check current history length
temporal workflow describe --workflow-id my-wf | grep -i "history"

# Programmatic check in workflow (TS)
const info = wf.workflowInfo();
if (info.historyLength > 5000) {
  await continueAsNew<typeof myWorkflow>(currentState);
}
```

```go
// Go — check inside workflow
info := workflow.GetInfo(ctx)
if info.GetCurrentHistoryLength() > 5000 {
    return workflow.NewContinueAsNewError(ctx, MyWorkflow, state)
}
```

---

## Worker Tuning

### Key Configuration Parameters

| Parameter (TS) | Default | Purpose |
|----------------|---------|---------|
| `maxConcurrentWorkflowTaskExecutions` | 40 | Parallel workflow tasks |
| `maxConcurrentActivityTaskExecutions` | 200 | Parallel activity executions |
| `maxCachedWorkflows` | 600 | Sticky execution cache size |
| `maxTaskQueueActivitiesPerSecond` | Unlimited | Rate limit across all workers |
| `maxConcurrentWorkflowTaskPolls` | 5 | Concurrent long-polls for workflow tasks |
| `maxConcurrentActivityTaskPolls` | 5 | Concurrent long-polls for activity tasks |

| Parameter (Go) | Default | Purpose |
|----------------|---------|---------|
| `MaxConcurrentWorkflowTaskExecutionSize` | 1000 | Parallel workflow tasks |
| `MaxConcurrentActivityExecutionSize` | 1000 | Parallel activity executions |
| `WorkerStopTimeout` | 0 | Grace period for in-flight tasks on shutdown |
| `MaxConcurrentWorkflowTaskPollers` | 2 | Concurrent workflow task long-polls |
| `MaxConcurrentActivityTaskPollers` | 2 | Concurrent activity task long-polls |

### Tuning Strategy

1. **Start with defaults**. Monitor before changing.
2. **CPU-bound activities**: Set `maxConcurrentActivityTaskExecutions` ≤ CPU cores.
3. **I/O-bound activities**: Can go higher (200-500), limited by open file handles and connections.
4. **Memory-bound workflows**: Reduce `maxCachedWorkflows` if workers OOM.
5. **Scale horizontally**: Add more workers rather than maxing out a single worker.

### Monitoring Worker Health

```bash
# Check task queue backlog
temporal task-queue describe --task-queue my-queue

# Watch for "pollers" count — should be >= 1
# Watch for "backlogCountHint" — should be low
```

Key Prometheus metrics:
- `temporal_sticky_cache_size` — current cache usage
- `temporal_workflow_task_schedule_to_start_latency` — queue wait time
- `temporal_activity_schedule_to_start_latency` — activity queue wait time
- `temporal_worker_task_slots_available` — available capacity

---

## Memory Issues

### Symptoms
- Worker process OOM killed
- Increasing RSS over time
- GC pauses causing workflow task timeouts

### Common Causes and Fixes

1. **Workflow cache too large**
   - Each cached workflow holds its execution state in memory
   - Fix: Reduce `maxCachedWorkflows` to match available memory
   - Rule of thumb: ~1-5 MB per cached workflow (depends on state size)

2. **Large activity payloads**
   - Activity results are held in memory during replay
   - Fix: Return references (URLs, IDs) instead of full data

3. **Goroutine/promise leaks (in workflow code)**
   - Spawning concurrent work without proper cleanup
   - Fix: Always await/join all spawned promises or goroutines

4. **Too many concurrent activities**
   - Each running activity consumes memory for its context and data
   - Fix: Reduce `maxConcurrentActivityTaskExecutions`

### Memory Sizing Formula

```
Worker memory ≈
  (maxCachedWorkflows × avg_workflow_state_size) +
  (maxConcurrentActivityTaskExecutions × avg_activity_memory) +
  base_process_overhead (100-200 MB)
```

Example: 600 cached workflows × 2 MB + 200 activities × 10 MB + 150 MB ≈ 3.35 GB

---

## gRPC Errors

### Common gRPC Error Codes

| Code | Meaning | Typical Cause | Fix |
|------|---------|---------------|-----|
| `UNAVAILABLE` | Server unreachable | Network issues, server down | Check connectivity, retry |
| `DEADLINE_EXCEEDED` | Request timeout | Server overloaded, slow DB | Increase timeout, check server health |
| `RESOURCE_EXHAUSTED` | Rate limited | Too many requests | Reduce request rate, increase server capacity |
| `NOT_FOUND` | Namespace/workflow missing | Wrong namespace, workflow completed | Check namespace and workflow ID |
| `ALREADY_EXISTS` | Duplicate workflow ID | Starting workflow with existing ID | Use unique IDs or `REJECT_DUPLICATE` policy |
| `PERMISSION_DENIED` | Auth failure | Bad mTLS certs, incorrect claims | Check certificates and RBAC config |
| `FAILED_PRECONDITION` | Invalid operation | Signaling completed workflow | Check workflow state before operations |

### Connection Issues

```typescript
// TypeScript — configure gRPC connection
const connection = await Connection.connect({
  address: 'temporal.example.com:7233',
  tls: {
    clientCertPair: { crt: readFileSync('client.pem'), key: readFileSync('client-key.pem') },
    serverRootCACertificate: readFileSync('ca.pem'),
  },
  // Increase keepalive for flaky networks
  channelArgs: {
    'grpc.keepalive_time_ms': 30000,
    'grpc.keepalive_timeout_ms': 15000,
    'grpc.keepalive_permit_without_calls': 1,
  },
});
```

### Debugging gRPC

```bash
# Enable gRPC debug logging
GRPC_VERBOSITY=DEBUG GRPC_TRACE=all temporal workflow list

# Test connectivity
grpcurl -plaintext localhost:7233 temporal.api.workflowservice.v1.WorkflowService/GetSystemInfo
```

---

## Namespace Configuration Problems

### Common Issues

1. **Namespace not found**: Create before use.
   ```bash
   temporal operator namespace create --namespace my-ns
   temporal operator namespace describe --namespace my-ns
   ```

2. **Retention period too short**: Completed workflows are deleted after the retention period.
   ```bash
   # Set retention to 30 days
   temporal operator namespace update --namespace my-ns --retention 720h
   ```

3. **Search attributes not registered**: Must be registered per namespace.
   ```bash
   temporal operator search-attribute create --namespace my-ns --name MyAttr --type Keyword
   temporal operator search-attribute list --namespace my-ns
   ```

4. **Namespace on wrong cluster**: In multi-cluster setups, ensure namespace is active on the correct cluster.
   ```bash
   temporal operator namespace describe --namespace my-ns | grep -i cluster
   ```

---

## Diagnostic Commands Cheat Sheet

```bash
# Server health
temporal operator cluster health

# List namespaces
temporal operator namespace list

# Describe task queue (check workers)
temporal task-queue describe --task-queue my-queue

# List running workflows
temporal workflow list --query 'ExecutionStatus="Running"'

# List failed workflows
temporal workflow list --query 'ExecutionStatus="Failed"'

# Show workflow history
temporal workflow show --workflow-id my-wf

# Describe specific workflow
temporal workflow describe --workflow-id my-wf

# Count workflows by status
temporal workflow count --query 'ExecutionStatus="Running"'
temporal workflow count --query 'ExecutionStatus="Failed"'
temporal workflow count --query 'ExecutionStatus="TimedOut"'

# Check for stuck workflows (running > 24h)
temporal workflow list --query 'ExecutionStatus="Running" AND StartTime < "2024-01-01T00:00:00Z"'

# Stack trace of a workflow (if supported)
temporal workflow stack --workflow-id my-wf

# Reset a workflow
temporal workflow reset --workflow-id my-wf --type LastWorkflowTask --reason "fix"

# Terminate stuck workflow
temporal workflow terminate --workflow-id my-wf --reason "stuck"

# Search attribute operations
temporal operator search-attribute list
temporal operator search-attribute create --name MyField --type Keyword
```
