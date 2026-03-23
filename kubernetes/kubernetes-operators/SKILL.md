---
name: kubernetes-operators
description:
  positive: "Use when user builds Kubernetes operators, asks about CRDs, custom controllers, kubebuilder, operator-sdk, controller-runtime, reconciliation loops, or extending the Kubernetes API."
  negative: "Do NOT use for using existing operators (Helm installs), kubectl usage, or basic Kubernetes resources (use kubernetes-troubleshooting skill)."
---

# Kubernetes Operators and Custom Resources

## Operator Pattern Fundamentals

The operator pattern extends Kubernetes by encoding operational knowledge into software. Core principles:

- **Controller pattern**: Watch resources, detect drift between desired and actual state, take corrective action.
- **Reconciliation loop**: A single `Reconcile` function called for every relevant event. Must converge toward desired state.
- **Declarative API**: Users declare intent in `.spec`; the controller drives reality to match.
- **Level-triggered, not edge-triggered**: React to current state, not to the event that caused it. Always re-read the resource before acting. Never cache assumptions across reconcile calls.

The reconcile function receives a `Request` (namespace/name), fetches the current object, computes desired state, and applies changes.

## Custom Resource Definitions (CRDs)
### Schema and Validation

Define CRDs with strict OpenAPI v3 schemas. Always separate `.spec` (user intent) from `.status` (controller observations).

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: databases.example.com
spec:
  group: example.com
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: [engine, replicas]
              properties:
                engine:
                  type: string
                  enum: [postgres, mysql]
                replicas:
                  type: integer
                  minimum: 1
                  maximum: 7
              x-kubernetes-validations:
                - rule: "self.replicas % 2 == 1"
                  message: "replicas must be odd for quorum"
            status:
              type: object
              properties:
                ready:
                  type: boolean
                conditions:
                  type: array
                  items:
                    type: object
                    properties:
                      type: { type: string }
                      status: { type: string }
                      reason: { type: string }
                      message: { type: string }
                      lastTransitionTime: { type: string, format: date-time }
      subresources:
        status: {}
  scope: Namespaced
  names:
    plural: databases
    singular: database
    kind: Database
    shortNames: [db]
```

### Key CRD Practices

- Use CEL (`x-kubernetes-validations`) for cross-field validation before resorting to webhooks.
- Enable the `/status` subresource so spec and status updates use separate RBAC.
- Version progression: `v1alpha1` → `v1beta1` → `v1`. Never make a new version the storage version immediately.

### Conversion Webhooks

Implement conversion webhooks only when schema changes are not structurally compatible across versions. Conversion must be lossless—round-trip between versions without data loss. Use hub-and-spoke model: pick one version as the hub, convert all others through it.

## Kubebuilder

### Scaffolding

```bash
kubebuilder init --domain example.com --repo github.com/org/operator
kubebuilder create api --group app --version v1alpha1 --kind Database
kubebuilder create webhook --group app --version v1alpha1 --kind Database \
  --defaulting --programmatic-validation
```

### Project Layout

```
├── api/v1alpha1/          # Types, deepcopy, webhook definitions
│   ├── database_types.go  # Spec/Status structs, markers
│   ├── database_webhook.go
│   └── groupversion_info.go
├── internal/controller/   # Reconciler implementations
│   └── database_controller.go
├── config/
│   ├── crd/               # Generated CRD manifests
│   ├── rbac/              # Generated RBAC from markers
│   ├── manager/           # Manager deployment
│   └── webhook/           # Webhook configs and certs
├── cmd/main.go            # Entry point, manager setup
└── Makefile               # Build, test, deploy targets
```

### Markers

Use markers to generate CRDs, RBAC, and webhook config:

```go
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Engine",type=string,JSONPath=`.spec.engine`
// +kubebuilder:printcolumn:name="Ready",type=boolean,JSONPath=`.status.ready`
// +kubebuilder:validation:Minimum=1
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
```

Run `make manifests` to regenerate CRDs and RBAC from markers.

## Operator SDK

Operator SDK wraps kubebuilder and adds OLM integration:
- **Go operators**: Full controller-runtime power for complex stateful workloads.
- **Ansible operators**: Map CRs to Ansible roles/playbooks. Set `reconcilePeriod` appropriately.
- **Helm operators**: Map CRs to Helm chart values for wrapping existing charts.

### OLM Integration

```bash
operator-sdk generate bundle --version 0.1.0
operator-sdk bundle validate ./bundle
operator-sdk scorecard ./bundle          # Validate bundle quality
operator-sdk run bundle quay.io/org/operator-bundle:v0.1.0
```

Package operators as OLM bundles with ClusterServiceVersion (CSV), CRDs, and RBAC.

## Controller-Runtime

### Core Components

```go
func main() {
    mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
        Scheme:                 scheme,
        LeaderElection:         true,
        LeaderElectionID:       "database-operator-lock",
        HealthProbeBindAddress: ":8081",
        MetricsBindAddress:     ":8080",
    })

    // Register reconciler with manager
    if err := (&DatabaseReconciler{
        Client: mgr.GetClient(),
        Scheme: mgr.GetScheme(),
    }).SetupWithManager(mgr); err != nil {
        setupLog.Error(err, "unable to create controller")
        os.Exit(1)
    }

    // Start manager (blocks until signal)
    if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
        os.Exit(1)
    }
}
```

- **Manager**: Owns shared cache, client, scheme, leader election, health probes, metrics.
- **Client**: Read/write to the API server. Reads go through cache by default.
- **Cache**: Shared informer cache. Use field/label selectors to reduce memory.
- **Scheme**: Maps Go types to GVKs.

### Event Handlers and Watches

```go
func (r *DatabaseReconciler) SetupWithManager(mgr ctrl.Manager) error {
    return ctrl.NewControllerManagedBy(mgr).
        For(&appv1alpha1.Database{}).                          // Primary resource
        Owns(&appsv1.Deployment{}).                            // Watch owned Deployments
        Owns(&corev1.Service{}).                               // Watch owned Services
        Watches(&corev1.Secret{},                              // Watch external Secrets
            handler.EnqueueRequestsFromMapFunc(r.findDatabasesForSecret),
            builder.WithPredicates(predicate.ResourceVersionChangedPredicate{}),
        ).
        WithOptions(controller.Options{MaxConcurrentReconciles: 3}).
        Complete(r)
}
```

Use `Owns()` for resources the controller creates. Use `Watches()` with `EnqueueRequestsFromMapFunc` for resources owned by others.

## Reconciliation Loop

### Canonical Structure```go
func (r *DatabaseReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    log := log.FromContext(ctx)

    // 1. Fetch the primary resource
    var db appv1alpha1.Database
    if err := r.Get(ctx, req.NamespacedName, &db); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    // 2. Handle deletion with finalizer
    if !db.DeletionTimestamp.IsZero() {
        return r.reconcileDelete(ctx, &db)
    }
    if !controllerutil.ContainsFinalizer(&db, finalizerName) {
        controllerutil.AddFinalizer(&db, finalizerName)
        return ctrl.Result{}, r.Update(ctx, &db)
    }

    // 3. Reconcile owned resources (idempotent)
    deployment, err := r.reconcileDeployment(ctx, &db)
    if err != nil {
        return ctrl.Result{}, err
    }

    svc, err := r.reconcileService(ctx, &db)
    if err != nil {
        return ctrl.Result{}, err
    }

    // 4. Update status
    db.Status.Ready = deployment.Status.ReadyReplicas == *deployment.Spec.Replicas
    db.Status.ObservedGeneration = db.Generation
    if err := r.Status().Update(ctx, &db); err != nil {
        return ctrl.Result{}, err
    }

    // 5. Requeue if not ready
    if !db.Status.Ready {
        return ctrl.Result{RequeueAfter: 10 * time.Second}, nil
    }
    return ctrl.Result{}, nil
}
```

### Rules

- Always re-fetch the resource at the start. Never trust stale data.
- Return `ctrl.Result{Requeue: true}` or `RequeueAfter` for transient states.
- Return an error to trigger exponential backoff requeue.
- Return `ctrl.Result{}, nil` only when fully reconciled.
- Make every operation idempotent. Use `CreateOrUpdate` or `CreateOrPatch`.

### CreateOrUpdate Pattern

```go
func (r *DatabaseReconciler) reconcileDeployment(ctx context.Context, db *appv1alpha1.Database) (*appsv1.Deployment, error) {
    dep := &appsv1.Deployment{
        ObjectMeta: metav1.ObjectMeta{
            Name:      db.Name,
            Namespace: db.Namespace,
        },
    }
    _, err := controllerutil.CreateOrUpdate(ctx, r.Client, dep, func() error {
        dep.Spec.Replicas = ptr.To(db.Spec.Replicas)
        dep.Spec.Selector = &metav1.LabelSelector{
            MatchLabels: map[string]string{"app": db.Name},
        }
        dep.Spec.Template = corev1.PodTemplateSpec{
            ObjectMeta: metav1.ObjectMeta{
                Labels: map[string]string{"app": db.Name},
            },
            Spec: corev1.PodSpec{
                Containers: []corev1.Container{{
                    Name:  "db",
                    Image: fmt.Sprintf("%s:latest", db.Spec.Engine),
                }},
            },
        }
        return controllerutil.SetControllerReference(db, dep, r.Scheme)
    })
    return dep, err
}
```

## Ownership and Garbage Collection

- Set `OwnerReferences` on every resource the controller creates via `controllerutil.SetControllerReference()`.
- Controller reference enables automatic garbage collection on parent deletion.
- Cross-namespace ownership is not supported. Use finalizers for cross-namespace cleanup.

## Status Management

### Conditions

```go
func setCondition(db *appv1alpha1.Database, condType string, status metav1.ConditionStatus, reason, message string) {
    meta.SetStatusCondition(&db.Status.Conditions, metav1.Condition{
        Type:               condType,
        Status:             status,
        ObservedGeneration: db.Generation,
        LastTransitionTime: metav1.Now(),
        Reason:             reason,
        Message:            message,
    })
}
```

- Use standard condition types: `Ready`, `Progressing`, `Degraded`, `Available`.
- Set `ObservedGeneration` on conditions and `.status.observedGeneration`.
- Update status via the `/status` subresource (`r.Status().Update()`).
- Never encode status in annotations or labels.

## Finalizers

```go
const finalizerName = "example.com/database-cleanup"

func (r *DatabaseReconciler) reconcileDelete(ctx context.Context, db *appv1alpha1.Database) (ctrl.Result, error) {
    if controllerutil.ContainsFinalizer(db, finalizerName) {
        // Perform external cleanup (cloud resources, DNS, etc.)
        if err := r.deleteExternalResources(ctx, db); err != nil {
            return ctrl.Result{}, err // Requeue on failure
        }
        controllerutil.RemoveFinalizer(db, finalizerName)
        if err := r.Update(ctx, db); err != nil {
            return ctrl.Result{}, err
        }
    }
    return ctrl.Result{}, nil
}
```

- Add finalizers before creating external resources.
- Remove finalizers only after successful cleanup.
- Handle the case where external resources are already gone (idempotent cleanup).

## Webhooks

### Validating Webhook

```go
// +kubebuilder:webhook:path=/validate-app-v1alpha1-database,mutating=false,failurePolicy=fail,groups=app.example.com,resources=databases,verbs=create;update,versions=v1alpha1,name=vdatabase.kb.io,admissionReviewVersions=v1

func (r *Database) ValidateCreate() (admission.Warnings, error) {
    if r.Spec.Engine == "mysql" && r.Spec.Replicas > 5 {
        return nil, fmt.Errorf("MySQL supports max 5 replicas")
    }
    return nil, nil
}
```

### Mutating Webhook

```go
// +kubebuilder:webhook:path=/mutate-app-v1alpha1-database,mutating=true,failurePolicy=fail,groups=app.example.com,resources=databases,verbs=create;update,versions=v1alpha1,name=mdatabase.kb.io,admissionReviewVersions=v1

func (r *Database) Default() {
    if r.Spec.Replicas == 0 {
        r.Spec.Replicas = 3
    }
}
```

### Certificate Management

Use cert-manager for webhook TLS. Kubebuilder scaffolds cert-manager integration. Set `failurePolicy: Fail` for critical validation; use `Ignore` only for non-essential webhooks.

## RBAC

Use kubebuilder markers to generate least-privilege RBAC:

```go
// +kubebuilder:rbac:groups=app.example.com,resources=databases,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=app.example.com,resources=databases/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=app.example.com,resources=databases/finalizers,verbs=update
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=services,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=events,verbs=create;patch
```

- Grant only the verbs actually used. Avoid wildcard `*` permissions.
- Use namespaced Roles for single-namespace operators; ClusterRoles for cluster-scoped CRDs.
- Create a dedicated ServiceAccount. Never use `default`.
- Grant `events` create/patch for recording events on managed resources.

## Testing

### Unit Testing Reconcilers

```go
func TestReconcile_CreatesDeployment(t *testing.T) {
    db := &appv1alpha1.Database{
        ObjectMeta: metav1.ObjectMeta{Name: "test-db", Namespace: "default"},
        Spec:       appv1alpha1.DatabaseSpec{Engine: "postgres", Replicas: 3},
    }
    fakeClient := fake.NewClientBuilder().
        WithScheme(scheme).
        WithObjects(db).
        WithStatusSubresource(db).
        Build()

    r := &DatabaseReconciler{Client: fakeClient, Scheme: scheme}
    result, err := r.Reconcile(context.TODO(), ctrl.Request{
        NamespacedName: types.NamespacedName{Name: "test-db", Namespace: "default"},
    })
    assert.NoError(t, err)

    var dep appsv1.Deployment
    err = fakeClient.Get(context.TODO(), types.NamespacedName{Name: "test-db", Namespace: "default"}, &dep)
    assert.NoError(t, err)
    assert.Equal(t, int32(3), *dep.Spec.Replicas)
}
```

### Integration Testing with envtest

```go
var testEnv *envtest.Environment

func TestMain(m *testing.M) {
    testEnv = &envtest.Environment{
        CRDDirectoryPaths: []string{filepath.Join("..", "..", "config", "crd", "bases")},
    }
    cfg, err := testEnv.Start()
    // ... set up manager, start controllers
    code := m.Run()
    testEnv.Stop()
    os.Exit(code)
}
```

- Use `envtest` for tests needing real API server behavior (validation, defaulting, admission).
- Use `fake.NewClientBuilder()` for fast unit tests of pure logic.
- Run e2e tests on kind clusters for full pod lifecycle.

## Deployment

### Kustomize (Default)

```bash
make docker-build docker-push IMG=registry.example.com/operator:v0.1.0
make deploy IMG=registry.example.com/operator:v0.1.0
```

### Helm

Package the operator as a Helm chart for Helm-standardized environments. Include CRDs in `crds/` directory.

### Versioning and Upgrades

- Tag operator images with semver. Never use `latest` in production.
- CRD upgrades must be backward-compatible. New fields must be optional with defaults.
- For OLM-managed operators, define `replaces` or `skips` in the CSV for upgrade graphs.

## Patterns

### State Machine

Model complex workflows as explicit states in `.status.phase`. Prefer conditions over phase for multi-dimensional status. Use phase only for simple linear progressions.

### Dependency Ordering

When one resource depends on another, reconcile in order and requeue if prerequisites are not ready.

### Multi-Resource Reconciliation

Use a single reconciler managing multiple child resource types. Each child type gets its own `reconcileX()` method. Use `Owns()` for each type.

### Leader Election

Always enable leader election for operators deployed with multiple replicas:

```go
ctrl.Options{
    LeaderElection:   true,
    LeaderElectionID: "database-operator-lock",
}
```

Only the leader runs reconciliation. Standbys take over on leader failure.

## Anti-Patterns

- **Polling instead of watches**: Never poll the API server in a loop. Use informers and watches.
- **Missing finalizers**: Leads to orphaned cloud resources on CR deletion.
- **Status as spec**: Never read `.status` to determine desired state. Status is output only.
- **Non-idempotent reconciliation**: Side effects that duplicate on re-run (double-creating resources, duplicate notifications).
- **Unbounded requeue**: Always use `RequeueAfter` with backoff, not tight loops.
- **Broad RBAC**: Requesting cluster-admin or wildcard permissions.
- **Blocking reconcile**: Never perform long-running operations synchronously. Create a Job or poll external status.
- **Ignoring conflicts**: Handle `StatusConflict` and `ResourceConflict` by re-fetching and retrying.
- **Hardcoded namespaces**: Use the resource's namespace from the request.
- **Missing ObservedGeneration**: Clients cannot distinguish stale from current status.
