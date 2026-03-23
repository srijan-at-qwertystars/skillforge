---
name: nomad-orchestration
description: >
  Guide for HashiCorp Nomad workload orchestration, job scheduling, and cluster management.
  TRIGGER when: user writes Nomad job specs (HCL), configures Nomad servers/clients,
  deploys containers or non-containerized workloads via Nomad, integrates Nomad with
  Consul or Vault, sets up Nomad ACLs, configures multi-region federation, manages
  Nomad networking (bridge/CNI), uses CSI storage plugins, implements rolling/canary/blue-green
  deployments, or configures the Nomad Autoscaler. Keywords: Nomad, HashiCorp, orchestration,
  workload scheduling, containers, non-containerized, task drivers, service discovery,
  nomad job, nomad agent, allocation, evaluation, deployment strategy.
  DO NOT TRIGGER when: user works with Kubernetes/K8s, Docker Compose, AWS ECS, or
  other non-Nomad orchestrators. Do not trigger for standalone Consul or Vault usage
  without Nomad context. Do not trigger for Terraform infrastructure provisioning unless
  it provisions Nomad clusters.
---

# HashiCorp Nomad Orchestration

Nomad (v1.10+) is a single-binary workload orchestrator that schedules containers, VMs, binaries, and Java applications. Unlike Kubernetes, Nomad has no external dependencies (no etcd), delegates service discovery to Consul and secrets to Vault, and scales to 10,000+ nodes with minimal operational overhead.

## Architecture

- **Servers**: Maintain cluster state via Raft consensus. Deploy 3 or 5 per region (always odd). One leader handles evaluation, planning, and scheduling.
- **Clients**: Run on every workload node. Fingerprint host resources, execute task drivers, report status to servers.
- **Regions**: Independent clusters with own server quorum. Federate for global orchestration.
- **Datacenters**: Logical groupings within a region for rack/AZ placement constraints.

**Data flow**: Job submitted → server creates **evaluation** → scheduler produces **allocation plan** → leader assigns **allocations** to clients → clients execute via **task drivers**.

```hcl
# Server configuration
server {
  enabled          = true
  bootstrap_expect = 3
  encrypt          = "GOSSIP_KEY"
}
tls {
  http = true
  rpc  = true
  ca_file   = "/etc/nomad.d/tls/ca.pem"
  cert_file = "/etc/nomad.d/tls/server.pem"
  key_file  = "/etc/nomad.d/tls/server-key.pem"
}
```

## Job Specification

Jobs use HCL. Hierarchy: **job → group → task**. Each group is a scheduling unit (allocation). All tasks in a group are co-located and share network/volumes.

```hcl
job "api" {
  region      = "us-east"
  datacenters = ["dc1", "dc2"]
  type        = "service"
  namespace   = "production"

  update {
    max_parallel     = 2
    min_healthy_time = "30s"
    healthy_deadline = "5m"
    auto_revert      = true
    canary           = 1
  }

  group "web" {
    count = 3

    spread {
      attribute = "${node.datacenter}"
    }

    network {
      mode = "bridge"
      port "http" { to = 8080 }
    }

    service {
      name     = "api-web"
      port     = "http"
      provider = "consul"

      check {
        type     = "http"
        path     = "/health"
        interval = "10s"
        timeout  = "3s"
      }

      connect {
        sidecar_service {
          proxy {
            upstreams {
              destination_name = "postgres"
              local_bind_port  = 5432
            }
          }
        }
      }
    }

    task "app" {
      driver = "docker"

      config {
        image = "myregistry/api:v1.2.3"
        ports = ["http"]
      }

      vault {
        policies = ["api-read"]
      }

      template {
        data = <<-EOF
          {{ with secret "database/creds/api" }}
          DB_USER={{ .Data.username }}
          DB_PASS={{ .Data.password }}
          {{ end }}
        EOF
        destination = "secrets/db.env"
        env         = true
      }

      resources {
        cpu    = 500
        memory = 256
      }
    }
  }
}
```

## Job Types

| Type | Purpose | Use Case |
|------|---------|----------|
| `service` | Long-running, rescheduled on failure | Web servers, APIs, databases |
| `batch` | Runs to completion | ETL, data processing, migrations |
| `system` | One instance per client node | Log collectors, monitoring agents |
| `sysbatch` | Batch that runs once per client | Node init, certificate rotation |

## Task Drivers

- **docker**: Primary driver. Set `image`, `ports`, `volumes`, `auth`. Supports all network modes.
- **exec**: Runs binaries in chroot with cgroup isolation. Requires `chroot_env` on client.
- **raw_exec**: No isolation. Disabled by default; enable with `plugin "raw_exec" { config { enabled = true } }`. Avoid in production.
- **java**: Runs JARs directly. Configure `jar_path`, `jvm_options`, `args`.
- **qemu**: Full VMs via QEMU/KVM. Set `image_path`, `accelerator`, `args`.
- **Community**: Podman, Firecracker, containerd, LXC. Install binaries in client plugin directory.

## Networking

**Modes**: `host` (default, direct bind) | `bridge` (Linux netns, requires CNI at `/opt/cni/bin`) | `cni/<name>` (custom CNI config in `/opt/cni/config`) | `none`.

```hcl
network {
  mode = "bridge"
  port "http" {
    static = 8080   # fixed host port
    to     = 80     # container port
  }
  port "grpc" {
    to = 9090       # dynamic host port → container 9090
  }
}
```

**Consul Connect**: Use `connect { sidecar_service {} }` to enroll in Consul service mesh. Envoy sidecars handle mTLS. Define `upstreams` for service-to-service calls over localhost.

## Service Discovery

**Nomad native** (`provider = "nomad"`): Built-in catalog, queryable via API. Use for simple discovery without Consul.

**Consul** (`provider = "consul"`): DNS-based discovery, health checking, service mesh, KV config. Register with tags for load balancer routing (Fabio, Traefik).

```hcl
service {
  name     = "cache"
  port     = "redis"
  provider = "consul"
  tags     = ["v1", "primary"]

  check {
    type     = "tcp"
    port     = "redis"
    interval = "10s"
    timeout  = "2s"
  }
}
```

## Storage

### Host Volumes

```hcl
# Client config
client {
  host_volume "data" {
    path      = "/opt/nomad/data"
    read_only = false
  }
}

# Job spec
group "db" {
  volume "data" {
    type   = "host"
    source = "data"
  }
  task "postgres" {
    volume_mount {
      volume      = "data"
      destination = "/var/lib/postgresql/data"
    }
  }
}
```

**Dynamic Host Volumes (v1.10+)**: Provision on demand — `nomad volume create -type host -name dbdata -node-id <id> -capacity 50GiB`.

### CSI Plugins

Run CSI controller/node plugins as Nomad jobs for external storage (EBS, GCP PD, Ceph, NFS):

```hcl
job "ebs-plugin" {
  type = "system"
  group "nodes" {
    task "plugin" {
      driver = "docker"
      config {
        image      = "amazon/aws-ebs-csi-driver:latest"
        privileged = true
      }
      csi_plugin {
        id        = "aws-ebs"
        type      = "node"
        mount_dir = "/csi"
      }
    }
  }
}
```

Reference CSI volumes in jobs: `volume "vol" { type = "csi" source = "my-vol" access_mode = "single-node-writer" attachment_mode = "file-system" }`.

## Deployments

### Rolling Updates

```hcl
update {
  max_parallel     = 1
  min_healthy_time = "30s"
  healthy_deadline = "5m"
  auto_revert      = true
}
```

### Canary

Set `canary = N` in `update`. Nomad deploys N canaries and pauses. Promote: `nomad deployment promote <id>`.

### Blue-Green

Set `canary` equal to `count`. All new allocations run alongside old. Promote to shift traffic; old drain.

```hcl
update {
  max_parallel = 3
  canary       = 3    # same as group count
  auto_promote = false
}
```

**Key commands**: `nomad job plan <file>` (dry-run) | `nomad job run -check-index <idx> <file>` (safe apply) | `nomad deployment promote <id>` | `nomad deployment fail <id>` (rollback).

## Autoscaling

Run the Nomad Autoscaler as a separate agent. Define `scaling` blocks in job specs:

```hcl
scaling {
  min     = 1
  max     = 20
  enabled = true

  policy {
    evaluation_interval = "30s"
    cooldown            = "3m"

    check "requests" {
      source = "prometheus"
      query  = "scalar(rate(http_requests_total{job='api'}[5m]))"
      strategy "target-value" {
        target = 1000
      }
    }
  }
}
```

**Cluster autoscaling**: Scale client pools via cloud APIs (AWS ASG, Azure VMSS, GCP MIG) using `target` plugins.

**Dynamic Application Sizing** (Enterprise): Auto-recommend and apply optimal CPU/memory per task from usage telemetry.

## Vault Integration

Configure on Nomad servers:

```hcl
vault {
  enabled = true
  address = "https://vault.service.consul:8200"
  default_identity {
    aud = ["vault.io"]
    ttl = "1h"
  }
}
```

Use `vault` block in tasks for policy binding. Use `template` to render secrets as files or env vars. See the job example above for usage.

**Workload Identity (v1.10+)**: Nomad issues JWT tokens per workload. Configure Vault's `jwt` auth method with Nomad's JWKS URL to eliminate long-lived tokens:

```shell
vault write auth/jwt-nomad/config \
  jwks_url="https://nomad.example.com/.well-known/jwks.json" \
  default_role="nomad-workloads"
```

## ACL System

Bootstrap: `nomad acl bootstrap` — store the management token securely. Enable in config: `acl { enabled = true }`.

```hcl
# Policy definition
namespace "production" {
  policy       = "write"
  capabilities = ["submit-job", "read-job", "list-jobs", "dispatch-job"]
}
namespace "default" {
  policy = "read"
}
node {
  policy = "read"
}
```

Apply and create tokens:

```shell
nomad acl policy apply prod-deploy prod-deploy.policy.hcl
nomad acl token create -name="ci-deploy" -policy="prod-deploy" -type="client"
```

In multi-region setups, designate one region as authoritative — it replicates ACL state to all federated regions.

## Multi-Region Federation

Set `authoritative_region` on all servers. Use `server_join` for cross-region connectivity.

```hcl
job "global-api" {
  type = "service"

  multiregion {
    strategy {
      max_parallel = 1
      on_failure   = "fail_all"
    }
    region "us-east-1" {
      count       = 3
      datacenters = ["dc1"]
    }
    region "eu-west-1" {
      count       = 2
      datacenters = ["dc1"]
    }
  }
}
```

Regions deploy sequentially per `max_parallel`. `on_failure = "fail_all"` auto-rollbacks across all regions.

## Monitoring and Observability

```hcl
telemetry {
  publish_allocation_metrics = true
  publish_node_metrics       = true
  prometheus_metrics         = true
}
```

**Key metrics**: `nomad.client.allocs.running` (active allocs) | `nomad.raft.commitTime` (consensus latency) | `nomad.nomad.blocked_evals.total_blocked` (scheduling pressure) | `nomad.client.allocs.cpu.total_ticks` / `memory.usage` (resource consumption).

Run `system` jobs for log shippers (Vector, Fluentd, Promtail) mounting `/alloc/logs`. Monitor Raft quorum with `nomad operator raft list-peers`. Check `/v1/agent/health` on all servers.

## Nomad vs Kubernetes Decision Guide

**Choose Nomad when**: mixed workloads (containers + VMs + binaries) | team lacks K8s expertise | already on HashiCorp stack | need simplicity (single binary, no etcd) | scaling beyond 5,000 nodes | edge/resource-constrained environments.

**Choose Kubernetes when**: exclusively containerized | need massive ecosystem (Helm, operators, CRDs) | org mandates CNCF tooling | using managed K8s (EKS/GKE/AKS) | need built-in RBAC/NetworkPolicy.

## Common Patterns

### Parameterized Batch Jobs

```hcl
job "report" {
  type = "batch"
  parameterized {
    payload       = "required"
    meta_required = ["customer_id"]
  }
  group "generate" {
    task "run" {
      driver = "docker"
      config {
        image = "myapp/report-gen:latest"
        args  = ["--customer", "${NOMAD_META_customer_id}"]
      }
      dispatch_payload { file = "input.json" }
    }
  }
}
```

Dispatch: `nomad job dispatch -meta customer_id=42 report @payload.json`

### Periodic Batch (Cron)

```hcl
periodic {
  crons            = ["0 2 * * *"]
  prohibit_overlap = true
  time_zone        = "UTC"
}
```

### Sidecar Pattern

Place multiple tasks in one group. They share network namespace and communicate over localhost.

### Service Dependencies

Use `template` blocks with `{{ service "dependency" }}` to block until upstream services are healthy in Consul.

## Anti-Patterns

- **Never use `raw_exec` in production** unless isolation is truly impossible — no cgroup/namespace protection.
- **Do not skip health checks.** Always define `check` blocks. Without them, traffic routes to unhealthy instances.
- **Do not hardcode secrets.** Use Vault `template` blocks — never embed credentials in job specs.
- **Do not use `static` ports unless required.** Dynamic ports maximize bin-packing and reduce conflicts.
- **Do not colocate servers and clients in production.** Separate for stability and security.
- **Do not ignore Raft quorum.** Losing quorum = cluster down. Monitor with `raft list-peers`; back up with `nomad operator snapshot save`.
- **Do not skip TLS and gossip encryption.** All production clusters must enforce mTLS and gossip keys.
- **Avoid single-region for critical services.** Use multi-region federation for DR.
