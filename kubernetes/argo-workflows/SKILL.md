---
name: argo-workflows
description: |
  Kubernetes-native workflow engine for CI/CD, ML, data processing. Use for complex workflows on K8s.
  NOT for simple cron jobs or non-K8s workflow systems.
---

# Argo Workflows

## Quick Start

```bash
# Install Argo Workflows
kubectl create namespace argo
kubectl apply -n argo -f https://github.com/argoproj/argo-workflows/releases/latest/download/install.yaml

# Port-forward UI
kubectl -n argo port-forward deployment/argo-server 2746:2746

# Submit workflow
argo submit workflow.yaml
argo list
argo logs <workflow-name>
argo delete <workflow-name>
```

## Workflow CRD Structure

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: hello-world-
spec:
  entrypoint: main          # Starting template
  templates:
    - name: main
      container:
        image: alpine:latest
        command: [echo, "hello world"]
```

## Templates

### Container Template
```yaml
templates:
  - name: run-tests
    container:
      image: golang:1.21
      command: [go, test, ./...]
      resources:
        requests:
          memory: "512Mi"
          cpu: "500m"
```

### Script Template (auto-capture output)
```yaml
templates:
  - name: generate-data
    script:
      image: python:3.11
      command: [python]
      source: |
        import json
        print(json.dumps({"value": 42}))
```

### DAG Template (dependencies)
```yaml
templates:
  - name: pipeline
    dag:
      tasks:
        - name: extract
          template: extract-data
        - name: transform
          template: process-data
          dependencies: [extract]
        - name: load
          template: save-data
          dependencies: [transform]
```

### Steps Template (sequential)
```yaml
templates:
  - name: build-and-push
    steps:
      - - name: build
          template: docker-build
      - - name: test
          template: run-tests
      - - name: push
          template: docker-push
```

## Artifacts

### S3 Artifact Repository
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: workflow-controller-configmap
data:
  artifactRepository: |
    s3:
      bucket: my-argo-bucket
      endpoint: s3.amazonaws.com
      region: us-west-2
      accessKeySecret:
        name: argo-artifacts
        key: accesskey
      secretKeySecret:
        name: argo-artifacts
        key: secretkey
```

### Input/Output Artifacts
```yaml
templates:
  - name: data-pipeline
    inputs:
      artifacts:
        - name: raw-data
          path: /data/input
          s3:
            key: inputs/dataset.csv
    outputs:
      artifacts:
        - name: processed-data
          path: /data/output/results.parquet
    container:
      image: data-processor:latest
```

### Artifact Passing Between Steps
```yaml
templates:
  - name: etl
    steps:
      - - name: extract
          template: extract
      - - name: transform
          template: transform
          arguments:
            artifacts:
              - name: raw-data
                from: "{{steps.extract.outputs.artifacts.raw-data}}"
```

## Parameters

### Workflow Parameters
```yaml
spec:
  arguments:
    parameters:
      - name: image-tag
        value: "latest"
      - name: environment
        value: "staging"
  templates:
    - name: deploy
      inputs:
        parameters:
          - name: image-tag
          - name: environment
      container:
        image: "myapp:{{inputs.parameters.image-tag}}"
        env:
          - name: ENV
            value: "{{inputs.parameters.environment}}"
```

### Global Parameters
```yaml
spec:
  arguments:
    parameters:
      - name: git-revision
        value: "main"
  templates:
    - name: checkout
      container:
        image: alpine/git
        command: [sh, -c]
        args: ["git clone --branch {{workflow.parameters.git-revision}} https://github.com/org/repo.git"]
```

## Volumes

### EmptyDir (ephemeral)
```yaml
templates:
  - name: workspace
    volumes:
      - name: workdir
        emptyDir: {}
    container:
      volumeMounts:
        - name: workdir
          mountPath: /workspace
```

### PVC (persistent)
```yaml
spec:
  volumeClaimTemplates:
    - metadata:
        name: data-volume
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 10Gi
  templates:
    - name: process-large-dataset
      container:
        volumeMounts:
          - name: data-volume
            mountPath: /data
```

### ConfigMap/Secret as Volume
```yaml
templates:
  - name: config-driven
    volumes:
      - name: config
        configMap:
          name: app-config
      - name: secrets
        secret:
          secretName: api-keys
    container:
      volumeMounts:
        - name: config
          mountPath: /etc/config
        - name: secrets
          mountPath: /etc/secrets
```

## Sidecars

### Database Sidecar
```yaml
templates:
  - name: test-with-db
    container:
      image: test-runner:latest
      command: [run-tests.sh]
    sidecars:
      - name: postgres
        image: postgres:15
        env:
          - name: POSTGRES_PASSWORD
            value: testpass
        readinessProbe:
          tcpSocket:
            port: 5432
          initialDelaySeconds: 5
```

## CronWorkflows

```yaml
apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
  name: nightly-etl
spec:
  schedule: "0 2 * * *"           # 2 AM daily
  timezone: "America/New_York"
  startingDeadlineSeconds: 60
  concurrencyPolicy: Forbid          # Skip if previous still running
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  suspend: false
  workflowSpec:
    entrypoint: etl
    templates:
      - name: etl
        container:
          image: etl-runner:latest
          command: [run-nightly.sh]
```

## Argo CLI

```bash
# Submit workflows
argo submit workflow.yaml
argo submit workflow.yaml -p param1=value1 -p param2=value2
argo submit --watch workflow.yaml

# List and inspect
argo list
argo get <workflow-name>
argo logs <workflow-name>
argo logs <workflow-name> -f                    # Follow

# Manage
argo delete <workflow-name>
argo delete --all --completed
argo stop <workflow-name>
argo resume <workflow-name>
argo retry <workflow-name>

# Cron workflows
argo cron list
argo cron get <cron-name>
argo cron create cronworkflow.yaml
argo cron delete <cron-name>
```

## Control Flow

### Conditionals
```yaml
templates:
  - name: conditional-deploy
    steps:
      - - name: check-branch
          template: get-branch
      - - name: deploy-prod
          template: deploy
          when: "{{steps.check-branch.outputs.result}} == main"
```

### Loops (withItems)
```yaml
templates:
  - name: process-files
    steps:
      - - name: process
          template: process-single
          arguments:
            parameters:
              - name: filename
                value: "{{item}}"
          withItems:
            - file1.csv
            - file2.csv
            - file3.csv
```

### Loops (withParam - JSON array)
```yaml
templates:
  - name: parallel-builds
    steps:
      - - name: build
          template: docker-build
          arguments:
            parameters:
              - name: service
                value: "{{item.name}}"
          withParam: "{{steps.generate-matrix.outputs.result}}"
```

### Retry Strategy
```yaml
templates:
  - name: flaky-task
    retryStrategy:
      limit: 3
      retryPolicy: OnError          # OnFailure, Always
      backoff:
        duration: "1m"
        factor: 2
        maxDuration: "10m"
    container:
      image: flaky-service:latest
```

### Suspend (manual approval)
```yaml
templates:
  - name: approval-gate
    steps:
      - - name: build
          template: build-image
      - - name: wait-for-approval
          template: suspend
      - - name: deploy
          template: deploy-prod

  - name: suspend
    suspend: {}
```

## Resource Templates (K8s Operations)

```yaml
templates:
  - name: create-job
    resource:
      action: create
      manifest: |
        apiVersion: batch/v1
        kind: Job
        metadata:
          generateName: data-import-
        spec:
          template:
            spec:
              containers:
                - name: importer
                  image: importer:latest
              restartPolicy: Never
```

## Exit Handlers (cleanup)

```yaml
spec:
  onExit: cleanup
  templates:
    - name: main
      steps:
        - - name: process
            template: data-processor
    - name: cleanup
      steps:
        - - name: notify-success
            template: slack-notify
            when: "{{workflow.status}} == Succeeded"
        - - name: notify-failure
            template: pagerduty-alert
            when: "{{workflow.status}} != Succeeded"
```

## Best Practices

### Resource Management
```yaml
spec:
  activeDeadlineSeconds: 3600      # Timeout entire workflow
  ttlStrategy:
    secondsAfterCompletion: 86400    # Auto-delete after 1 day
  templates:
    - name: bounded-task
      activeDeadlineSeconds: 600     # Per-template timeout
      container:
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "1000m"
```

### Security
```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
  templates:
    - name: secure-task
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
```

### Service Account per Workflow
```yaml

## Troubleshooting

**Pod stuck in Pending**: `kubectl describe pod <pod-name> -n argo && kubectl top nodes`

**Artifact upload fails**: `kubectl get configmap workflow-controller-configmap -n argo -o yaml`

**Workflow not starting**: `kubectl logs -n argo deployment/workflow-controller`

### Debug Commands
```bash
argo get <name> -o yaml
kubectl get events -n argo --field-selector involvedObject.name=<workflow-name>
kubectl exec -it <pod-name> -n argo -c main -- sh
```

### Workflow Status Reference
- `Pending` - Waiting for resources
- `Running` - Active execution
- `Succeeded` - Completed successfully
- `Failed` - Error occurred
- `Error` - System error
- `Skipped` - Conditional skip
- `Omitted` - Template not executed
