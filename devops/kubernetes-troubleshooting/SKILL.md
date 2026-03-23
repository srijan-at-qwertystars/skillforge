---
name: kubernetes-troubleshooting
description:
  positive: "Use when user debugs Kubernetes issues, asks about CrashLoopBackOff, ImagePullBackOff, pending pods, OOMKilled, networking problems, DNS issues, kubectl debug, or why a deployment/service isn't working."
  negative: "Do NOT use for Kubernetes installation, Helm chart creation (use helm-chart-patterns skill), or cluster architecture design."
---

# Kubernetes Troubleshooting

## Systematic Debugging Workflow

Follow this order for every issue:

```bash
# 1. Describe — get current state, conditions, events
kubectl describe pod <pod>
kubectl describe deployment <deploy>

# 2. Logs — check container output
kubectl logs <pod> -c <container>
kubectl logs <pod> --previous          # logs from last crashed container
kubectl logs <pod> --all-containers    # all containers in pod
kubectl logs -l app=myapp --tail=100   # by label

# 3. Events — cluster-wide context
kubectl get events -n <ns> --sort-by='.lastTimestamp'
kubectl get events --field-selector involvedObject.name=<pod>

# 4. Exec / Debug — interactive investigation
kubectl exec -it <pod> -- /bin/sh
kubectl debug -it <pod> --image=nicolaka/netshoot --target=<container>
```

Always check: pod status → describe → logs → events → exec/debug.

---

## Pod Failure States

### CrashLoopBackOff

Pod starts, crashes, restarts with exponential backoff.

```bash
kubectl logs <pod> --previous
kubectl describe pod <pod> | grep -A5 "Last State"
```

Causes: app error, missing config/secret/env var, failing liveness probe, bad entrypoint, missing dependency.
Fixes: check logs, verify ConfigMaps/Secrets, relax liveness probe `initialDelaySeconds`, add init containers for dependency checks.

### ImagePullBackOff / ErrImagePull

```bash
kubectl describe pod <pod> | grep -A3 "Events"
```

Causes: image tag typo/doesn't exist, private registry without `imagePullSecrets`, Docker Hub rate limit, network blocked.
Fixes: verify image exists (`docker manifest inspect <image>:<tag>`), create pull secret, check `imagePullPolicy`.

### Pending

Pod cannot be scheduled.

```bash
kubectl describe pod <pod> | grep -A10 "Events"
kubectl get nodes -o wide
kubectl describe nodes | grep -A5 "Allocated resources"
```

Causes: insufficient CPU/memory, node selector/affinity mismatch, taints without tolerations, PVC not bound, ResourceQuota exceeded.

### OOMKilled

Container exceeded its memory limit. Exit code 137.

```bash
kubectl describe pod <pod> | grep -i oom
kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'
kubectl top pod <pod> --containers
```

Fixes: increase `resources.limits.memory`, profile app memory, fix leaks, set requests ~20-30% above peak, check JVM `-Xmx` vs container limit.

### Evicted

Node under resource pressure evicted the pod.

```bash
kubectl get pods --field-selector=status.phase=Failed | grep Evicted
kubectl describe node <node> | grep -A5 "Conditions"
```

Fixes: set proper resource requests, use PriorityClasses, clean node disk, delete evicted pods: `kubectl delete pods --field-selector=status.phase=Failed`

---

## Container Debugging

### kubectl debug (Ephemeral Containers — GA since K8s 1.25+)

```bash
# Attach debug container to running pod (shares namespaces)
kubectl debug -it <pod> --image=busybox --target=<container>

# Full networking toolkit
kubectl debug -it <pod> --image=nicolaka/netshoot --target=<container>

# Copy pod for safe debugging (won't affect production)
kubectl debug <pod> --copy-to=debug-pod --container=debug --image=ubuntu -- sleep infinity

# Override entrypoint on crash-looping pod
kubectl debug <pod> --copy-to=debug-pod --set-image=*=ubuntu -- sleep infinity

# Debug a node directly
kubectl debug node/<node> -it --image=busybox
```

### Exec into Running Containers

```bash
kubectl exec -it <pod> -c <container> -- /bin/sh
kubectl exec <pod> -- cat /etc/config/app.yaml
kubectl exec <pod> -- env | grep DATABASE
kubectl exec <pod> -- wget -qO- http://localhost:8080/healthz
```

### Distroless / Minimal Images

Use ephemeral containers — they share PID and network namespace with the target:

```bash
kubectl debug -it <pod> --image=busybox --target=<container>
# Inside: ls /proc/1/root/  to see target filesystem
```

---

## Networking Troubleshooting

### Service Not Reachable

```bash
# 1. Verify Service exists and has correct selector
kubectl get svc <svc> -o wide
kubectl describe svc <svc>

# 2. Check endpoints — empty means no matching pods
kubectl get endpoints <svc>

# 3. Verify pod labels match service selector
kubectl get pods --show-labels | grep <app-label>

# 4. Test connectivity from inside cluster
kubectl run test-curl --rm -it --image=curlimages/curl --restart=Never -- curl <svc>.<ns>.svc.cluster.local:<port>
```

Causes: selector mismatch, pod not Ready (failing readiness probe), wrong targetPort, ClusterIP not externally accessible.

### DNS Resolution

```bash
# Test DNS from a debug pod
kubectl run dns-test --rm -it --image=busybox --restart=Never -- nslookup <svc>.<ns>.svc.cluster.local

# Check CoreDNS health
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50

# Verify resolv.conf inside pod
kubectl exec <pod> -- cat /etc/resolv.conf

# Check CoreDNS config
kubectl -n kube-system get configmap coredns -o yaml
```

Common causes: CoreDNS not running, NetworkPolicy blocking port 53 UDP/TCP, wrong `ndots` setting, search domain issues — use FQDN.

### NetworkPolicy

```bash
# List policies affecting a namespace
kubectl get networkpolicy -n <ns>
kubectl describe networkpolicy <policy> -n <ns>

# Test: temporarily allow all traffic
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-all-debug
  namespace: <ns>
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  ingress: [{}]
  egress: [{}]
EOF

# If traffic works now, incrementally tighten the policy
# Clean up after debugging
kubectl delete networkpolicy allow-all-debug -n <ns>
```

### Ingress Issues

```bash
kubectl get ingress -n <ns>
kubectl describe ingress <ingress>
kubectl get pods -n <ingress-controller-ns>
kubectl logs -n <ingress-controller-ns> -l app.kubernetes.io/name=ingress-nginx --tail=100
```

Check: host/path rules, TLS secret exists, backend service reachable, ingress class annotation.
---

## Resource Issues

### CPU Throttling

```bash
kubectl top pods -n <ns> --sort-by=cpu
kubectl top nodes

# Check if limits are set too low
kubectl get pod <pod> -o jsonpath='{.spec.containers[*].resources}'
```

Symptoms: high latency, slow responses. Fix: increase `resources.limits.cpu` or remove CPU limits (use requests only). Monitor: `container_cpu_cfs_throttled_seconds_total` in Prometheus.

### Memory Pressure (Node-level)

```bash
kubectl describe node <node> | grep -A5 "Conditions"
kubectl top nodes
```

Fix: evict non-critical pods, add nodes, increase node size, set proper resource requests.

### Disk Pressure

```bash
kubectl describe node <node> | grep DiskPressure
# On the node:
kubectl debug node/<node> -it --image=busybox
# Then: df -h, du -sh /var/log, du -sh /var/lib/containerd
```

Fix: clean container logs, prune unused images, rotate logs, expand disk.

### ResourceQuota

```bash
kubectl get resourcequota -n <ns>
kubectl describe resourcequota -n <ns>
```

If pod is Pending due to quota: reduce requests, increase quota, or clean up unused resources.

---

## Deployment Problems

### Rollout Stuck

```bash
kubectl rollout status deployment/<deploy> -n <ns>
kubectl get replicaset -n <ns> -l app=<app>
kubectl describe deployment <deploy>

# Check new ReplicaSet's pods
kubectl get pods -l app=<app> --sort-by='.metadata.creationTimestamp'
```

Causes: new pods failing (crash, image pull, resources), `maxUnavailable: 0` with no capacity, PDB blocking disruption, quota exceeded.

### Rollback

```bash
kubectl rollout undo deployment/<deploy>
kubectl rollout undo deployment/<deploy> --to-revision=<N>
kubectl rollout history deployment/<deploy>
```

### Failed Update

```bash
# Check what changed
kubectl rollout history deployment/<deploy> --revision=<N>

# Compare current vs previous
kubectl diff -f deployment.yaml
```

---

## PersistentVolume Issues

### PVC Stuck in Pending

```bash
kubectl get pvc -n <ns>
kubectl describe pvc <pvc>
kubectl get pv
kubectl get storageclass
```

Causes: no matching PV (size/accessMode/storageClass mismatch), provisioner not installed, volume zone mismatch, PV stuck in Released state.

Fixes:
- Verify StorageClass name matches PVC spec
- Use `WaitForFirstConsumer` binding mode for zone-aware provisioning
- Clear stale PV: `kubectl patch pv <pv> -p '{"spec":{"claimRef": null}}'`
- Check CSI driver pods: `kubectl get pods -n kube-system | grep csi`

### Mount Errors

```bash
kubectl describe pod <pod> | grep -A5 "Warning"
```

Common: `Multi-Attach error` (RWO on multiple nodes), filesystem corruption, permission denied.
Fix: ensure accessMode matches usage, check `fsGroup` in securityContext.

---

## RBAC and Permissions Debugging

```bash
# Test if a user/SA can perform an action
kubectl auth can-i create pods --as=system:serviceaccount:<ns>:<sa>
kubectl auth can-i list secrets --as=<user> -n <ns>

# List all permissions for a service account
kubectl auth can-i --list --as=system:serviceaccount:<ns>:<sa>

# Find relevant roles and bindings
kubectl get roles,rolebindings -n <ns>
kubectl get clusterroles,clusterrolebindings | grep <name>
kubectl describe rolebinding <binding> -n <ns>

# Common error pattern
# "pods is forbidden: User ... cannot <verb> resource ..."
# → Create or fix Role/ClusterRole and bind it
```

Quick fix for debugging (remove after):
```bash
kubectl create clusterrolebinding debug-admin --clusterrole=cluster-admin --serviceaccount=<ns>:<sa>
# Test, then delete
kubectl delete clusterrolebinding debug-admin
```

---

## Node Problems

### Node NotReady

```bash
kubectl get nodes
kubectl describe node <node> | grep -A10 "Conditions"

# Check kubelet status (from node or debug pod)
kubectl debug node/<node> -it --image=busybox
# Then: chroot /host systemctl status kubelet
```

Common causes: kubelet stopped, network partition, disk/memory pressure, certificate expired.
### Taints and Tolerations

```bash
# View node taints
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

# Check if pod tolerates node taints
kubectl get pod <pod> -o jsonpath='{.spec.tolerations}'

# Remove a taint
kubectl taint nodes <node> key=value:NoSchedule-
```

### Cordoned Nodes

```bash
kubectl get nodes | grep SchedulingDisabled
kubectl uncordon <node>
```

### Drain Issues

```bash
# If drain hangs
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --force --timeout=300s
# Check PDBs blocking drain
kubectl get pdb -A
```

---

## kubectl Power Commands

```bash
# Events sorted by time (most useful single command)
kubectl get events -n <ns> --sort-by='.lastTimestamp'
kubectl get events -A --sort-by='.metadata.creationTimestamp' | tail -20

# Find pods not running
kubectl get pods -A --field-selector=status.phase!=Running

# Resource usage
kubectl top pods -n <ns> --sort-by=memory
kubectl top nodes

# JSONPath extraction
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[-1].type}{"\n"}{end}'

# Custom columns
kubectl get pods -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName,RESTARTS:.status.containerStatuses[0].restartCount
kubectl get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.capacity.cpu,MEM:.status.capacity.memory

# Find pods with high restart counts
kubectl get pods -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount --sort-by='.status.containerStatuses[0].restartCount'

# Get all images running in cluster
kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | sort -u

# Resource requests vs limits across namespace
kubectl get pods -n <ns> -o custom-columns=NAME:.metadata.name,CPU_REQ:.spec.containers[0].resources.requests.cpu,CPU_LIM:.spec.containers[0].resources.limits.cpu,MEM_REQ:.spec.containers[0].resources.requests.memory,MEM_LIM:.spec.containers[0].resources.limits.memory
```

---

## Debugging Tools

### stern — Multi-pod Log Tailing

```bash
stern <pod-name-regex>                      # tail logs matching name
stern <regex> -n <ns>                       # in specific namespace
stern <regex> -c <container>                # specific container
stern <regex> --since 5m                    # last 5 minutes
stern <regex> -o json                       # JSON output
stern . -n <ns> --exclude "health"          # all pods, exclude pattern
```

### k9s — Terminal UI

```bash
k9s                                          # launch
k9s -n <ns>                                  # in namespace
k9s --context <ctx>                          # specific context
# Inside k9s:
# :pod, :deploy, :svc, :ns                  — navigate resources
# /pattern                                   — filter
# l — logs, s — shell, d — describe, y — yaml
# ctrl-d — delete, ctrl-k — kill
```

### kubectl-debug Plugin

```bash
# Install via krew
kubectl krew install debug

# Debug with shared process namespace
kubectl debug -it <pod> --image=nicolaka/netshoot --target=<container> --share-processes
```

---

## Decision Trees

### Pod Not Starting

1. Status `Pending`? → Check events: scheduling, resource, PVC, taint issues
2. Status `ContainerCreating`? → Check image pull, volume mount, init containers
3. Status `CrashLoopBackOff`? → Check `logs --previous`, entrypoint, config
4. Status `ImagePullBackOff`? → Check image name, registry auth, network
5. Status `Running` but not ready? → Check readiness probe, app startup time

### Service Not Working

1. Service exists? → `kubectl get svc`
2. Endpoints populated? → `kubectl get endpoints <svc>` (empty = selector mismatch)
3. Pod labels match? → Compare `svc.spec.selector` with `pod.metadata.labels`
4. Pods ready? → `kubectl get pods` (must be Running + Ready)
5. Port correct? → Check `targetPort` matches container port
6. DNS resolves? → `nslookup <svc>.<ns>.svc.cluster.local`
7. NetworkPolicy blocking? → Check policies in namespace

### App Slow or Unresponsive

1. CPU throttled? → `kubectl top pods`, check limits
2. Memory near limit? → `kubectl top pods --containers`
3. Too few replicas? → Check HPA status, scale up
4. Network latency? → Test with `curl -w` from debug pod
5. Dependent service slow? → Check upstream health
6. Disk I/O? → Check node disk pressure, PV performance
