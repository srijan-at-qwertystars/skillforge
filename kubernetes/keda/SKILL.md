---
name: keda
description: |
  Kubernetes event-driven autoscaling for containers. Use for scaling workloads based on events/queues.
  NOT for simple HPA-based CPU/memory scaling.
tested: true
---

# KEDA: Kubernetes Event-Driven Autoscaling

## Quick Reference

| Resource | Purpose | When to Use |
|----------|---------|-------------|
| `ScaledObject` | Scale Deployments/StatefulSets | Event-driven workloads with continuous processing |
| `ScaledJob` | Scale Jobs | One-time/batch processing of events |
| `TriggerAuthentication` | Auth for scalers | External triggers need secrets/credentials |
| `ClusterTriggerAuthentication` | Cluster-wide auth | Shared auth across namespaces |

## ScaledObject: Event-Driven Deployment Scaling

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: kafka-consumer-scaler
  namespace: production
spec:
  scaleTargetRef:
    name: my-consumer-deployment
    kind: Deployment
    apiVersion: apps/v1
  pollingInterval: 30
  cooldownPeriod: 300
  minReplicaCount: 0
  maxReplicaCount: 100
  advanced:
    restoreToOriginalReplicaCount: false
    horizontalPodAutoscalerConfig:
      behavior:
        scaleDown:
          stabilizationWindowSeconds: 300
          policies:
            - type: Percent
              value: 10
              periodSeconds: 60
  triggers:
    - type: kafka
      metadata:
        bootstrapServers: kafka-cluster:9092
        consumerGroup: my-consumer-group
        topic: orders-topic
        lagThreshold: "100"
        activationLagThreshold: "10"
```

**Key Fields:**
- `pollingInterval`: How often to check metrics (seconds)
- `cooldownPeriod`: Wait before scaling down (seconds)
- `minReplicaCount: 0`: Scale to zero when no events
- `activationLagThreshold`: Lag needed to wake from zero

## ScaledJob: Event-Driven Job Scaling

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledJob
metadata:
  name: queue-processor-jobs
  namespace: batch
spec:
  jobTargetRef:
    template:
      spec:
        containers:
          - name: processor
            image: myapp/batch-processor:v1.2
            env:
              - name: QUEUE_URL
                value: "https://sqs.us-east-1.amazonaws.com/123456789/my-queue"
        restartPolicy: Never
    backoffLimit: 4
    ttlSecondsAfterFinished: 300
  pollingInterval: 30
  maxReplicaCount: 50
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 2
  triggers:
    - type: aws-sqs-queue
      authenticationRef:
        name: aws-auth
      metadata:
        queueURL: https://sqs.us-east-1.amazonaws.com/123456789/my-queue
        queueLength: "5"
        awsRegion: us-east-1
```

**Job-Specific Fields:**
- `successfulJobsHistoryLimit`: Keep last N successful jobs
- `failedJobsHistoryLimit`: Keep last N failed jobs
- `ttlSecondsAfterFinished`: Auto-cleanup completed jobs

## TriggerAuthentication: Secure Credential Management

```yaml
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: kafka-auth
  namespace: production
spec:
  secretTargetRef:
    - parameter: sasl
      name: kafka-secrets
      key: sasl-mechanism
    - parameter: username
      name: kafka-secrets
      key: username
    - parameter: password
      name: kafka-secrets
      key: password
  # Pod Identity (EKS/IRSA, AKS, GKE)
  podIdentity:
    provider: aws
    identityOwner: keda-operator  # or pod
```

**Auth Methods:**
- `secretTargetRef`: Reference Kubernetes secrets
- `configMapTargetRef`: Reference ConfigMaps
- `env`: Reference container env vars
- `podIdentity`: Cloud provider workload identity

## Common Scalers

### Kafka
```yaml
triggers:
  - type: kafka
    metadata:
      bootstrapServers: kafka:9092
      consumerGroup: my-group
      topic: events
      lagThreshold: "100"
      activationLagThreshold: "10"
      offsetResetPolicy: latest
```

### Redis (Streams)
```yaml
triggers:
  - type: redis-streams
    metadata:
      address: redis:6379
      stream: my-stream
      consumerGroup: my-group
      pendingEntriesCount: "10"
    authenticationRef:
      name: redis-auth
```

### RabbitMQ
```yaml
triggers:
  - type: rabbitmq
    metadata:
      protocol: amqp
      queueName: task-queue
      mode: QueueLength
      value: "20"
      hostFromEnv: RABBITMQ_HOST
    authenticationRef:
      name: rabbitmq-auth
```

### AWS SQS
```yaml
triggers:
  - type: aws-sqs-queue
    authenticationRef:
      name: aws-auth
    metadata:
      queueURL: https://sqs.us-east-1.amazonaws.com/123/queue
      queueLength: "5"
      awsRegion: us-east-1
```

### Prometheus (Custom Metrics)
```yaml
triggers:
  - type: prometheus
    metadata:
      serverAddress: http://prometheus:9090
      metricName: http_requests_per_second
      threshold: "100"
      query: |
        sum(rate(http_requests_total{service="api"}[2m]))
```

### PostgreSQL
```yaml
triggers:
  - type: postgresql
    metadata:
      connectionFromEnv: PG_CONNECTION_STRING
      query: "SELECT COUNT(*) FROM jobs WHERE status='pending'"
      targetQueryValue: "10"
```

## Multi-Trigger Scaling

Scale based on multiple metrics (OR logic - scales if ANY trigger active):

```yaml
spec:
  triggers:
    # Scale if Kafka lag OR CPU high
    - type: kafka
      name: kafka-trigger
      metadata:
        bootstrapServers: kafka:9092
        topic: events
        lagThreshold: "100"
    - type: cpu
      name: cpu-trigger
      metadata:
        type: Utilization
        value: "70"
```

## HPA Integration

KEDA creates HPAs automatically. View with:

```bash
# List KEDA-created HPAs
kubectl get hpa -l app.kubernetes.io/managed-by=keda-operator

# View HPA details
kubectl describe hpa keda-hpa-kafka-consumer-scaler
```

**Custom HPA Behavior:**
```yaml
spec:
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleUp:
          stabilizationWindowSeconds: 0
          policies:
            - type: Percent
              value: 100
              periodSeconds: 15
        scaleDown:
          stabilizationWindowSeconds: 300
          policies:
            - type: Percent
              value: 10
              periodSeconds: 60
```

## Installation

```bash
# Helm install
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda --namespace keda --create-namespace

# Verify
kubectl get pods -n keda
kubectl get crd | grep keda
```

## Verification & Debugging

```bash
# Check ScaledObject status
kubectl get scaledobject -n production
kubectl describe scaledobject kafka-consumer-scaler -n production

# View KEDA operator logs
kubectl logs -n keda deployment/keda-operator

# Check metrics server
kubectl logs -n keda deployment/keda-metrics-apiserver

# Verify HPA status
kubectl get hpa -n production
kubectl describe hpa keda-hpa-kafka-consumer-scaler -n production

# Check scaler activity
kubectl get events -n production --field-selector reason=KEDAScaleTarget
```

## Best Practices

**Scale-to-Zero:**
```yaml
spec:
  minReplicaCount: 0
  triggers:
    - type: kafka
      metadata:
        lagThreshold: "100"
        activationLagThreshold: "10"  # Wake at 10, sleep at 0
```

**Cooldown Tuning:**
```yaml
spec:
  cooldownPeriod: 300  # 5 min before scale-down
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleDown:
          stabilizationWindowSeconds: 300  # HPA stabilization
```

**Resource Limits:**
```yaml
spec:
  maxReplicaCount: 100
  advanced:
    scalingModifiers:
      formula: "min(100, x)"  # Cap at 100 regardless
```

**Multiple ScaledObjects:**
- One ScaledObject per Deployment
- Multiple triggers = OR logic
- For AND logic, use external metric aggregation

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Not scaling up | Auth failure | Check TriggerAuthentication, secrets |
| Not scaling to zero | activationLagThreshold | Verify threshold > 0, check metric |
| Erratic scaling | Polling too frequent | Increase pollingInterval |
| Scale-down too fast | cooldownPeriod too low | Increase to 300+ seconds |
| HPA not found | KEDA not installed | Verify keda-operator pods |
| Metrics unavailable | metrics-server down | Check keda-metrics-apiserver |

**Debug Commands:**
```bash
# Check scaled object conditions
kubectl get scaledobject my-scaler -o jsonpath='{.status.conditions}'

# Verify trigger authentication
kubectl get triggerauthentication -o yaml

# Test scaler connectivity
kubectl exec -it keda-operator-xxx -n keda -- sh
# Then test connection to your event source
```

## Cloud Provider Identity

**AWS (IRSA):**
```yaml
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: aws-irsa
spec:
  podIdentity:
    provider: aws
    identityOwner: keda-operator  # or pod
```

**Azure (Workload Identity):**
```yaml
spec:
  podIdentity:
    provider: azure-workload
```

**GCP (Workload Identity):**
```yaml
spec:
  podIdentity:
    provider: gcp-workload
```

## Migration from HPA

Before (HPA only):
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 1
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

After (KEDA with CPU fallback):
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: my-keda-scaler
spec:
  scaleTargetRef:
    name: my-app
  minReplicaCount: 0
  maxReplicaCount: 10
  triggers:
    - type: kafka
      metadata:
        bootstrapServers: kafka:9092
        topic: events
        lagThreshold: "100"
    - type: cpu
      metadata:
        type: Utilization
        value: "70"
```

## Advanced Patterns

**Cron Scaler (Time-based):**
```yaml
triggers:
  - type: cron
    metadata:
      timezone: America/New_York
      start: 0 9 * * 1-5
      end: 0 17 * * 1-5
      desiredReplicas: "10"
```

**External Scaler (gRPC):**
```yaml
triggers:
  - type: external
    metadata:
      scalerAddress: my-scaler-service:50051
      metricName: custom_metric
      threshold: "100"
```

**ScaledObject with Fallback:**
```yaml
spec:
  fallback:
    failureThreshold: 3
    replicas: 6
  triggers:
    - type: kafka
      metadata:
        lagThreshold: "100"
```
