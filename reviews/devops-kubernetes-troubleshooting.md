# Review: kubernetes-troubleshooting

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5

Issues: Non-standard description format uses `positive:`/`negative:` sub-keys.

Excellent skill. Covers systematic debugging workflow (describe→logs→events→exec), pod failure states (CrashLoopBackOff, ImagePullBackOff, Pending, OOMKilled, Evicted), container debugging with kubectl debug (ephemeral containers GA K8s 1.25+), networking troubleshooting (service, DNS, CoreDNS, NetworkPolicy, Ingress), resource issues (CPU throttling, memory/disk pressure, ResourceQuota), deployment problems (rollout stuck, rollback), PV issues (PVC pending, mount errors), RBAC debugging, node problems (NotReady, taints, cordon/drain), kubectl power commands (JSONPath, custom columns), debugging tools (stern, k9s), and decision trees for pod/service/performance issues.
