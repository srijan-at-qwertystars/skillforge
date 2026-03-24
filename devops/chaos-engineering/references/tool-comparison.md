# Chaos Engineering Tool Comparison

## Table of Contents

- [Quick Decision Matrix](#quick-decision-matrix)
- [Chaos Mesh](#chaos-mesh)
- [LitmusChaos](#litmuschaos)
- [Gremlin](#gremlin)
- [AWS Fault Injection Simulator (FIS)](#aws-fault-injection-simulator-fis)
- [Chaos Monkey](#chaos-monkey)
- [Feature Comparison Table](#feature-comparison-table)
- [Selection Guide](#selection-guide)

---

## Quick Decision Matrix

```
Need K8s-native, fine-grained faults?         → Chaos Mesh
Need workflow orchestration + experiment hub?  → LitmusChaos
Need enterprise SaaS, multi-platform?          → Gremlin
Need AWS-native, integrated with IAM/CW?      → AWS FIS
Need simple instance termination?              → Chaos Monkey
Need app-level network simulation?             → Toxiproxy (see SKILL.md)
```

---

## Chaos Mesh

### Overview
Kubernetes-native chaos engineering platform using CRDs. CNCF Incubating project.

### Fault Types Supported
| Category | Faults |
|----------|--------|
| Pod | pod-kill, pod-failure, container-kill |
| Network | delay, loss, corruption, partition, bandwidth, duplicate, DNS |
| Stress | CPU, memory |
| I/O | latency, fault, attribute override |
| Time | clock skew (time travel) |
| HTTP | abort, delay, replace (body/headers) |
| DNS | error, random |
| JVM | exception, GC, latency, method return value |
| Kernel | kernel fault injection |

### Architecture
```
┌──────────────────────────────────┐
│          Chaos Dashboard         │  (Web UI)
├──────────────────────────────────┤
│       Chaos Controller Manager   │  (Reconciliation loop)
├──────────────────────────────────┤
│    Chaos Daemon (per node)       │  (Executes faults via cgroups/tc/iptables)
├──────────────────────────────────┤
│         Kubernetes API           │  (CRDs: NetworkChaos, PodChaos, etc.)
└──────────────────────────────────┘
```

### Installation
```bash
# Helm (recommended)
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm install chaos-mesh chaos-mesh/chaos-mesh -n chaos-mesh --create-namespace \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock

# Verify
kubectl get pods -n chaos-mesh
```

### Strengths
- Deepest fault injection variety of any OSS tool
- CRD-based — GitOps friendly, version-controlled experiments
- Clock skew injection (unique to Chaos Mesh)
- JVM-specific faults for Java services
- Kernel fault injection for low-level testing
- Web dashboard for visualization

### Weaknesses
- Kubernetes only — no VM or bare-metal support
- Requires DaemonSet with privileged access (security concern)
- No built-in experiment orchestration / workflow engine
- Steeper learning curve than LitmusChaos
- Limited cloud-provider-specific faults (no native AWS/GCP actions)

### Pricing
**Free** — fully open source (Apache 2.0)

### Community
- CNCF Incubating project
- GitHub: ~7k stars
- Active development, regular releases
- Growing contributor base

---

## LitmusChaos

### Overview
Kubernetes-native chaos engineering framework with experiment orchestration, ChaosHub marketplace, and CI/CD integration. CNCF Incubating project (Harness-backed).

### Fault Types Supported
| Category | Faults |
|----------|--------|
| Pod | pod-delete, pod-cpu-hog, pod-memory-hog, pod-network-loss, pod-dns-error |
| Node | node-drain, node-taint, kubelet-service-kill, node-cpu-hog, node-memory-hog |
| Network | pod-network-latency, pod-network-loss, pod-network-corruption, pod-network-partition |
| AWS | ec2-terminate, ebs-loss, ec2-stop, rds-instance-reboot |
| GCP | gcp-vm-instance-stop, gcp-vm-disk-loss |
| Azure | azure-instance-stop, azure-disk-loss |

### Architecture
```
┌─────────────────────────────────────┐
│          ChaosCenter (UI)           │  (Experiment management, analytics)
├─────────────────────────────────────┤
│      Workflow Controller            │  (Argo Workflows-based orchestration)
├─────────────────────────────────────┤
│      Chaos Operator                 │  (ChaosEngine reconciliation)
├─────────────────────────────────────┤
│      ChaosHub                       │  (Experiment marketplace)
├─────────────────────────────────────┤
│      Subscriber (per cluster)       │  (Multi-cluster support)
└─────────────────────────────────────┘
```

### Installation
```bash
# Helm
helm repo add litmuschaos https://litmuschaos.github.io/litmus-helm/
helm install litmus litmuschaos/litmus -n litmus --create-namespace

# Access ChaosCenter
kubectl get svc -n litmus  # Find ChaosCenter frontend service
```

### Strengths
- Workflow orchestration — chain multiple experiments with probes and checks
- ChaosHub marketplace — 100+ pre-built experiments
- Cloud-provider faults (AWS, GCP, Azure) — not just Kubernetes
- Health probes — validate steady state within experiment definition
- Multi-cluster support via ChaosCenter
- CI/CD integration (GitHub Actions, GitLab CI, Jenkins)
- Excellent documentation and tutorials

### Weaknesses
- Heavier installation footprint (ChaosCenter, MongoDB, etc.)
- Fewer low-level fault types than Chaos Mesh (no clock skew, JVM, kernel)
- Argo Workflows dependency adds complexity
- Enterprise features behind Harness paywall

### Pricing
- **Open source**: Free (Apache 2.0)
- **Enterprise (Harness)**: Custom pricing — adds RBAC, SaaS management, SSO

### Community
- CNCF Incubating project
- GitHub: ~4.5k stars
- Large experiment contributor community
- Extensive ChaosHub with community-contributed experiments

---

## Gremlin

### Overview
Commercial SaaS chaos engineering platform. Agent-based, works across VMs, containers, Kubernetes, and cloud services. Enterprise-focused with strong safety controls.

### Fault Types Supported
| Category | Faults |
|----------|--------|
| State | shutdown, process kill, time travel |
| Network | latency, packet loss, DNS, blackhole, certificate expiry |
| Resource | CPU, memory, disk, I/O |
| Application | HTTP faults (via sidecar), certificate chaos |

### Architecture
```
┌─────────────────────────────────┐
│      Gremlin SaaS Control Plane │  (Hosted by Gremlin)
├─────────────────────────────────┤
│      Gremlin Web UI / API       │  (Scenario builder, reporting)
├─────────────────────────────────┤
│      Gremlin Agent (per host)   │  (Executes attacks locally)
├─────────────────────────────────┤
│      Target Infrastructure      │  (VMs, containers, K8s pods)
└─────────────────────────────────┘
```

### Strengths
- **Multi-platform**: VMs, bare metal, containers, Kubernetes — not K8s-only
- **Enterprise features**: RBAC, teams, audit logs, SSO/SAML, SOC 2 compliant
- **Scenarios**: Chain multiple attacks with conditions and delays
- **Safety**: Built-in halt mechanisms, magnitude controls, blast radius limits
- **Ease of use**: GUI-driven, low barrier to entry for non-SRE teams
- **Status checks**: Integrated health checks during experiments
- **Support**: Dedicated support, professional services, training

### Weaknesses
- **Cost**: Significant — starts ~$300/month, enterprise pricing scales with targets
- **Closed source**: No source code access, vendor lock-in risk
- **Agent dependency**: Requires Gremlin agent on every target
- **Limited customization**: Can't extend fault types beyond what Gremlin provides
- **Data residency**: Control plane is Gremlin-hosted (SaaS)

### Pricing
| Tier | Price (approx.) | Features |
|------|----------------|----------|
| Free | $0 | 1 target, limited attacks |
| Team | ~$300/mo | 10 targets, scenarios, RBAC |
| Enterprise | Custom | Unlimited targets, SSO, audit, support |

### Community
- Proprietary — no open-source community
- Active blog, webinars, and documentation
- Large enterprise customer base (Fortune 500)

---

## AWS Fault Injection Simulator (FIS)

### Overview
Fully managed AWS service for running fault injection experiments against AWS resources. Integrated with IAM, CloudWatch, and EventBridge.

### Fault Types Supported
| Category | Faults |
|----------|--------|
| EC2 | stop, terminate, reboot, API errors, spot interruption |
| ECS | drain container instances, stop tasks |
| EKS | terminate node group instances, pod faults (via Chaos Mesh integration) |
| RDS | reboot, failover, instance crash |
| Network | disrupt connectivity (VPC, subnet, security group manipulation) |
| Systems Manager | CPU stress, memory stress, network disruption (via SSM agent) |
| Lambda | add function invocation errors |
| CloudWatch | disable alarms (test alert dependencies) |

### Architecture
```
┌──────────────────────────────────────────┐
│           AWS FIS Service                │
│  ┌────────────────┐  ┌────────────────┐  │
│  │  Experiment    │  │  Stop          │  │
│  │  Templates     │  │  Conditions    │  │
│  └────────────────┘  └────────────────┘  │
│           │                    │          │
│  ┌────────▼────────┐  ┌──────▼───────┐  │
│  │  IAM Role       │  │  CloudWatch  │  │
│  │  (permissions)  │  │  Alarms      │  │
│  └─────────────────┘  └──────────────┘  │
├──────────────────────────────────────────┤
│        Target AWS Resources              │
│   EC2  ECS  EKS  RDS  Lambda  ...        │
└──────────────────────────────────────────┘
```

### Strengths
- **Native AWS integration**: IAM for permissions, CloudWatch for stop conditions, EventBridge for triggers
- **No agent required**: Uses AWS APIs directly (except SSM-based faults)
- **Managed service**: No infrastructure to run or maintain
- **Stop conditions**: Automatic halt based on CloudWatch alarms
- **Compliance**: AWS shared responsibility model, CloudTrail audit logs
- **Resource targeting**: Fine-grained with tags, filters, percentage-based selection

### Weaknesses
- **AWS only**: Zero support for other clouds or on-premises
- **Limited fault variety**: Fewer fault types than Chaos Mesh or Gremlin
- **Cost**: Pay per action-minute (~$0.10/action-minute), adds up at scale
- **No workflow orchestration**: Single experiment at a time, no chaining
- **Blast radius limitations**: Some actions affect entire resources (can't inject pod-level faults natively)
- **EKS support**: Requires Chaos Mesh integration for pod-level faults

### Pricing
| Component | Cost |
|-----------|------|
| Action-minute | ~$0.10/min |
| Example: 5 actions × 10 min | ~$5.00 |
| Example: monthly (100 experiments) | ~$500/mo |

### Community
- AWS-managed, closed source
- Extensive AWS documentation and tutorials
- AWS re:Invent sessions, blog posts
- Support via AWS Support plans

---

## Chaos Monkey

### Overview
Netflix's original chaos engineering tool. Randomly terminates instances in production to ensure services can survive instance failures. Part of the Simian Army.

### Fault Types Supported
| Category | Faults |
|----------|--------|
| Instance | Random termination only |

### Strengths
- **Pioneer**: Established chaos engineering as a discipline
- **Simple**: Does one thing well — kill instances
- **Production-proven**: Netflix has run it in production for 10+ years
- **Spinnaker integration**: Native integration with Spinnaker CD
- **Lightweight**: Minimal resource footprint

### Weaknesses
- **Very limited scope**: Only kills instances — no network, resource, or application faults
- **Spinnaker dependency**: Designed to work with Spinnaker; awkward without it
- **Minimal Kubernetes support**: Designed for VM/instance-based architectures
- **No safety controls**: No built-in abort conditions or blast radius management
- **Low maintenance**: Infrequent updates, limited active development
- **No UI**: CLI only, no dashboard or visualization

### Pricing
**Free** — open source (Apache 2.0)

### Community
- GitHub: ~14k stars (historical popularity)
- Limited active development
- Legacy status — widely referenced, less actively used

---

## Feature Comparison Table

| Feature | Chaos Mesh | LitmusChaos | Gremlin | AWS FIS | Chaos Monkey |
|---------|-----------|-------------|---------|---------|-------------|
| **License** | Apache 2.0 | Apache 2.0 | Proprietary | Managed SaaS | Apache 2.0 |
| **CNCF Status** | Incubating | Incubating | — | — | — |
| **Deployment** | K8s operator | K8s operator | Agent + SaaS | AWS managed | App (Spinnaker) |
| **K8s Support** | ★★★★★ | ★★★★★ | ★★★★ | ★★★ (EKS) | ★ |
| **VM/Bare Metal** | ✗ | ✗ | ✓ | ✓ (EC2) | ✓ |
| **Multi-Cloud** | Via K8s | Via K8s + native | ✓ | AWS only | AWS mainly |
| **Pod Faults** | ✓ | ✓ | ✓ | Via Chaos Mesh | ✗ |
| **Network Faults** | ✓ | ✓ | ✓ | ✓ | ✗ |
| **CPU/Memory Stress** | ✓ | ✓ | ✓ | ✓ (SSM) | ✗ |
| **I/O Faults** | ✓ | ✗ | ✓ | ✗ | ✗ |
| **DNS Faults** | ✓ | ✓ | ✓ | ✗ | ✗ |
| **Clock Skew** | ✓ | ✗ | ✓ | ✗ | ✗ |
| **JVM Faults** | ✓ | ✗ | ✗ | ✗ | ✗ |
| **HTTP Faults** | ✓ | ✗ | ✓ (sidecar) | ✗ | ✗ |
| **Cloud Provider Faults** | ✗ | ✓ (AWS/GCP/Azure) | ✗ | ✓ (AWS) | ✗ |
| **Workflow Orchestration** | ✗ | ✓ (Argo) | ✓ (Scenarios) | ✗ | ✗ |
| **Experiment Marketplace** | ✗ | ✓ (ChaosHub) | ✗ | Templates | ✗ |
| **Web UI** | ✓ | ✓ (ChaosCenter) | ✓ | AWS Console | ✗ |
| **CI/CD Integration** | kubectl | Native | API/CLI | AWS CLI | Spinnaker |
| **RBAC** | K8s native | Built-in | Built-in | IAM | ✗ |
| **Abort Conditions** | Duration only | Health probes | Built-in | CloudWatch | ✗ |
| **Audit Trail** | K8s events | Built-in | Built-in | CloudTrail | ✗ |
| **Ease of Setup** | Medium | Medium | Easy | Easy (AWS) | Hard |
| **Learning Curve** | Steep | Moderate | Low | Low (AWS users) | Low |
| **Cost** | Free | Free / Enterprise | $$$ | Pay-per-use | Free |

---

## Selection Guide

### By Team Profile

**Platform/SRE team, K8s-native, wants maximum fault variety:**
→ **Chaos Mesh** — deepest fault injection, CRD-based, GitOps compatible

**DevOps team, K8s + cloud, wants orchestration and CI/CD integration:**
→ **LitmusChaos** — workflow engine, ChaosHub, multi-cloud support

**Enterprise, multi-platform (VMs + K8s + cloud), wants managed solution:**
→ **Gremlin** — SaaS, easy onboarding, enterprise features, support

**AWS-only shop, wants native integration with minimal setup:**
→ **AWS FIS** — IAM integration, CloudWatch stop conditions, no agents

**Just starting out, want to build chaos muscle with minimal investment:**
→ **Chaos Mesh** or **LitmusChaos** — free, well-documented, community support

### By Use Case

| Use Case | Recommended Tool |
|----------|-----------------|
| Pod/container chaos in K8s | Chaos Mesh or LitmusChaos |
| Network chaos in K8s | Chaos Mesh |
| AWS resource faults (EC2, RDS) | AWS FIS |
| Multi-cloud resource faults | LitmusChaos |
| VM/bare-metal chaos | Gremlin |
| CI/CD chaos gate | LitmusChaos |
| Enterprise with compliance needs | Gremlin or AWS FIS |
| Clock skew testing | Chaos Mesh |
| JVM-specific faults | Chaos Mesh |
| Application-level network faults | Toxiproxy |
| Simple instance kill | Chaos Monkey |

### Migration Path

Common progression as teams mature:
```
Chaos Monkey / manual scripts (L1)
  → Chaos Mesh or LitmusChaos (L2-L3)
    → + AWS FIS for cloud-specific faults (L3)
      → + Gremlin for enterprise/multi-platform (L4)
```
