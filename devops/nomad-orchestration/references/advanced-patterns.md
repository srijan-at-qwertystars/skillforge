# Advanced Nomad Patterns

## Table of Contents

- [Parameterized Jobs](#parameterized-jobs)
- [Dispatch Jobs](#dispatch-jobs)
- [Periodic Batch Jobs](#periodic-batch-jobs)
- [Multi-Region Deployments](#multi-region-deployments)
- [Nomad Pack](#nomad-pack)
- [Nomad Variables](#nomad-variables)
- [CSI Volumes in Production](#csi-volumes-in-production)
- [Template Stanza Patterns](#template-stanza-patterns)
- [Constraint and Affinity Strategies](#constraint-and-affinity-strategies)
- [Spread Scheduling](#spread-scheduling)
- [Preemption](#preemption)
- [Device Plugins and GPU Scheduling](#device-plugins-and-gpu-scheduling)

---

## Parameterized Jobs

Parameterized jobs are batch job templates invoked at runtime with metadata and/or payloads. They act like functions — define once, dispatch many times with different inputs.

### Defining a Parameterized Job

```hcl
job "etl-pipeline" {
  type = "batch"

  parameterized {
    payload       = "required"          # "optional", "required", or "forbidden"
    meta_required = ["source_table"]    # must be provided at dispatch
    meta_optional = ["dry_run"]         # optional overrides
  }

  group "process" {
    task "transform" {
      driver = "docker"

      config {
        image = "myorg/etl:v3.1"
        args  = [
          "--source", "${NOMAD_META_source_table}",
          "--dry-run", "${NOMAD_META_dry_run}",
        ]
      }

      dispatch_payload {
        file = "config.json"     # payload written to this file in task dir
      }

      resources {
        cpu    = 2000
        memory = 1024
      }
    }
  }
}
```

### Key Rules

- Parameterized jobs **do not run until dispatched**. They stay in a "parameterized" state.
- Each dispatch creates an independent child job with its own allocation.
- `meta_required` keys **must** be supplied or dispatch fails.
- `dispatch_payload` writes the raw payload bytes into the specified file inside the task working directory.
- Child jobs inherit the parent spec but are independently tracked (status, logs, GC).

### Dispatch Command

```shell
# With metadata and payload file
nomad job dispatch -meta source_table=users -meta dry_run=false etl-pipeline @input.json

# API dispatch
curl -X POST "${NOMAD_ADDR}/v1/job/etl-pipeline/dispatch" \
  -H "X-Nomad-Token: ${NOMAD_TOKEN}" \
  -d '{"Meta": {"source_table": "users"}, "Payload": "'$(base64 input.json)'"}'
```

### Best Practices

- Set `resources` conservatively — each dispatch consumes cluster capacity.
- Use `meta_optional` with defaults in your entrypoint rather than requiring every parameter.
- Implement idempotency in your task so re-dispatches are safe.
- Set GC thresholds on the server (`job_gc_threshold`) to avoid accumulating thousands of child jobs.

---

## Dispatch Jobs

Dispatch is the mechanism for invoking parameterized jobs. Beyond basic dispatch, advanced patterns include:

### Chained Dispatches

Orchestrate multi-stage pipelines by having each stage dispatch the next:

```shell
# Stage 1 task script dispatches stage 2 on completion
nomad job dispatch -meta input_path="/data/stage1_output" stage2-job
```

### Programmatic Dispatch via API

Build dispatch into application code for event-driven architectures:

```python
import requests

def dispatch_report(customer_id: str, payload: dict):
    resp = requests.post(
        f"{NOMAD_ADDR}/v1/job/report-gen/dispatch",
        headers={"X-Nomad-Token": NOMAD_TOKEN},
        json={
            "Meta": {"customer_id": customer_id},
            "Payload": base64.b64encode(json.dumps(payload).encode()).decode(),
        },
    )
    return resp.json()["DispatchedJobID"]
```

### Monitoring Dispatched Jobs

```shell
# List all dispatched children
nomad job status -all-allocs etl-pipeline

# Watch a specific dispatch
nomad alloc logs -f <alloc-id>
```

---

## Periodic Batch Jobs

Periodic jobs are Nomad's distributed cron. The scheduler launches a new instance of the job at each cron tick.

### Configuration

```hcl
job "nightly-backup" {
  type = "batch"

  periodic {
    crons            = ["0 2 * * *"]     # 2 AM daily (supports multiple crons)
    prohibit_overlap = true              # skip tick if previous run still active
    time_zone        = "America/New_York"
  }

  group "backup" {
    task "dump" {
      driver = "docker"
      config {
        image   = "myorg/db-backup:latest"
        command = "/backup.sh"
      }
      resources {
        cpu    = 1000
        memory = 512
      }
    }
  }
}
```

### Advanced Periodic Patterns

**Multiple schedules**: Use multiple cron entries for complex timing:

```hcl
periodic {
  crons = [
    "0 */6 * * *",    # every 6 hours
    "30 2 * * 0",     # Sunday 2:30 AM (weekly deep clean)
  ]
}
```

**Force launch**: Trigger a periodic job outside its schedule:

```shell
nomad job periodic force nightly-backup
```

### Gotcha: Periodic + Parameterized

Do **not** combine `periodic` and `parameterized` on the same job. Each periodic launch creates a parameterized job instance, which then requires separate dispatch — almost never what you want. Instead, use two separate jobs: one periodic for scheduled runs, one parameterized for ad-hoc triggers.

---

## Multi-Region Deployments

Multi-region federation allows a single job spec to deploy across independent Nomad regions with coordinated rollouts.

### Federation Setup

Each region runs its own server cluster. All regions must agree on an `authoritative_region` for global state (ACL policies, Sentinel policies):

```hcl
# Server config — all regions
server {
  enabled            = true
  authoritative_region = "us-east-1"
}
```

Cross-region connectivity via WAN gossip:

```hcl
server_join {
  retry_join = ["provider=aws tag_key=NomadServer tag_value=global"]
}
```

### Multi-Region Job Spec

```hcl
job "global-api" {
  type = "service"

  multiregion {
    strategy {
      max_parallel = 1          # deploy one region at a time
      on_failure   = "fail_all" # rollback all regions on failure
    }

    region "us-east-1" {
      count       = 5
      datacenters = ["dc1", "dc2"]
      meta {
        region_label = "US East"
      }
    }

    region "eu-west-1" {
      count       = 3
      datacenters = ["dc1"]
      meta {
        region_label = "EU West"
      }
    }

    region "ap-southeast-1" {
      count       = 2
      datacenters = ["dc1"]
    }
  }

  # ... group and task definitions
}
```

### Deployment Flow

1. Job submitted to any region → forwarded to authoritative region.
2. Authoritative region coordinates deployment across regions per `max_parallel`.
3. Each region deploys independently using its local `update` strategy.
4. If any region fails and `on_failure = "fail_all"`, all regions auto-revert.

### Best Practices

- Use `max_parallel = 1` to catch failures in the first region before proceeding.
- Pair with canary deployments in each region's `update` block for double safety.
- Ensure clock synchronization (NTP) across regions for consistent evaluation timing.
- Monitor cross-region latency — federation adds gossip overhead.

---

## Nomad Pack

Nomad Pack is a templating and packaging tool (like Helm for Kubernetes). It generates Nomad job specs from reusable templates with variable substitution.

### Core Concepts

- **Pack**: A directory containing templates, variables, and metadata.
- **Registry**: A Git repo hosting packs (default: `github.com/hashicorp/nomad-pack-community-registry`).
- **Variables**: Override defaults at deploy time.

### Directory Structure

```
my-pack/
├── metadata.hcl          # name, version, description
├── variables.hcl          # variable declarations with defaults
├── templates/
│   ├── job.nomad.tpl      # Go template producing HCL
│   └── helpers.tpl        # shared template functions
└── README.md
```

### Usage

```shell
# Add a registry
nomad-pack registry add community github.com/hashicorp/nomad-pack-community-registry

# List available packs
nomad-pack registry list

# Deploy with variable overrides
nomad-pack run nginx --var image=nginx:1.25 --var count=3

# Render without deploying (for review)
nomad-pack render nginx --var image=nginx:1.25

# Destroy a deployed pack
nomad-pack destroy nginx
```

### Writing Custom Packs

```hcl
# variables.hcl
variable "image" {
  description = "Docker image"
  type        = string
  default     = "nginx:latest"
}

variable "count" {
  description = "Number of instances"
  type        = number
  default     = 1
}
```

```gotpl
// templates/job.nomad.tpl
job "[[.nomad_pack.pack.name]]" {
  type = "service"
  group "app" {
    count = [[ .my_pack.count ]]
    task "server" {
      driver = "docker"
      config {
        image = "[[ .my_pack.image ]]"
      }
    }
  }
}
```

---

## Nomad Variables

Nomad Variables (v1.4+) provide a secure, namespaced key-value store built into Nomad. They replace many use cases previously requiring Consul KV or external config.

### Creating Variables

```shell
# CLI
nomad var put nomad/jobs/api-config db_host=postgres.service.consul db_port=5432

# From file
nomad var put nomad/jobs/api-config @config.json
```

### Accessing in Job Specs

```hcl
template {
  data = <<-EOF
    {{ with nomadVar "nomad/jobs/api-config" }}
    DB_HOST={{ .db_host }}
    DB_PORT={{ .db_port }}
    {{ end }}
  EOF
  destination = "local/config.env"
  env         = true
}
```

### Path-Based ACLs

Variables are scoped by path. ACL policies control access:

```hcl
namespace "production" {
  variables {
    path "nomad/jobs/*" {
      capabilities = ["read"]
    }
    path "nomad/jobs/api-config" {
      capabilities = ["read", "write"]
    }
  }
}
```

### Nomad Variables vs. Vault vs. Consul KV

| Feature | Nomad Variables | Vault | Consul KV |
|---------|----------------|-------|-----------|
| Built-in to Nomad | Yes | No (external) | No (external) |
| Encryption at rest | Yes (server-side) | Yes | No (by default) |
| Dynamic secrets | No | Yes | No |
| TTL / lease management | No | Yes | No |
| Best for | App config, feature flags | Credentials, certificates | Service config, shared state |

**Rule of thumb**: Use Nomad Variables for non-secret configuration. Use Vault for credentials and certificates. Use Consul KV only if you need cross-service shared state.

---

## CSI Volumes in Production

Container Storage Interface (CSI) support lets Nomad manage external storage (EBS, GCP PD, Ceph, NFS) via standardized plugins.

### Architecture

CSI requires two plugin types running as Nomad jobs:

1. **Controller plugin** — manages volume lifecycle (create, delete, attach). Runs as a `service` job (1 instance).
2. **Node plugin** — mounts volumes on each client. Runs as a `system` job (every node).

### Controller Plugin Job

```hcl
job "ebs-controller" {
  type = "service"

  group "controller" {
    count = 1

    task "plugin" {
      driver = "docker"
      config {
        image      = "public.ecr.aws/ebs-csi-driver/aws-ebs-csi-driver:v1.28.0"
        args       = ["controller"]
        privileged = true
      }

      csi_plugin {
        id        = "aws-ebs"
        type      = "controller"
        mount_dir = "/csi"
      }

      resources {
        cpu    = 256
        memory = 256
      }
    }
  }
}
```

### Node Plugin Job

```hcl
job "ebs-node" {
  type = "system"

  group "nodes" {
    task "plugin" {
      driver = "docker"
      config {
        image      = "public.ecr.aws/ebs-csi-driver/aws-ebs-csi-driver:v1.28.0"
        args       = ["node"]
        privileged = true
      }

      csi_plugin {
        id        = "aws-ebs"
        type      = "node"
        mount_dir = "/csi"
      }

      resources {
        cpu    = 128
        memory = 128
      }
    }
  }
}
```

### Volume Registration and Usage

```shell
# Register a volume
nomad volume register ebs-vol.hcl

# Volume definition file (ebs-vol.hcl)
id           = "mysql-data"
name         = "mysql-data"
type         = "csi"
plugin_id    = "aws-ebs"
capacity_min = "10GiB"
capacity_max = "50GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

mount_options {
  fs_type     = "ext4"
  mount_flags = ["noatime"]
}
```

### Using CSI Volumes in Jobs

```hcl
group "database" {
  volume "data" {
    type            = "csi"
    source          = "mysql-data"
    read_only       = false
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }

  task "mysql" {
    volume_mount {
      volume      = "data"
      destination = "/var/lib/mysql"
    }
  }
}
```

### Production Tips

- Always pin CSI driver versions — `latest` tags cause unpredictable behavior.
- Set `per_alloc = true` on volumes if each allocation needs its own volume.
- Monitor CSI plugin health: `nomad plugin status aws-ebs`.
- Test failover: kill a node plugin and verify volumes remount on the replacement node.
- Use `snapshot` commands for volume backups before upgrades.

---

## Template Stanza Patterns

The `template` stanza renders dynamic configuration files using Go templates with access to Consul, Vault, Nomad Variables, and environment data.

### Pattern 1: Vault Secret Injection

```hcl
template {
  data = <<-EOF
    {{ with secret "database/creds/api-role" }}
    DATABASE_URL=postgres://{{ .Data.username }}:{{ .Data.password }}@db.internal:5432/app
    {{ end }}
  EOF
  destination = "secrets/db.env"
  env         = true
  change_mode = "restart"    # restart task when secret rotates
}
```

### Pattern 2: Consul Service Discovery

```hcl
template {
  data = <<-EOF
    {{ range service "redis" }}
    REDIS_HOST={{ .Address }}
    REDIS_PORT={{ .Port }}
    {{ end }}
  EOF
  destination = "local/redis.env"
  env         = true
  change_mode = "restart"
}
```

### Pattern 3: Dynamic Nginx Config

```hcl
template {
  data = <<-EOF
    upstream backend {
      {{ range service "api-web" }}
      server {{ .Address }}:{{ .Port }};
      {{ end }}
    }
    server {
      listen 80;
      location / {
        proxy_pass http://backend;
      }
    }
  EOF
  destination = "local/nginx.conf"
  change_mode = "signal"
  change_signal = "SIGHUP"   # reload nginx without restart
}
```

### Pattern 4: Wait-for-Dependency

```hcl
template {
  data = <<-EOF
    {{ range service "postgres" }}
    DB_READY=true
    {{ end }}
  EOF
  destination   = "local/deps.env"
  env           = true
  wait {
    min = "5s"
    max = "30s"
  }
}
```

The template blocks until the Consul service is registered and healthy, effectively creating a dependency gate.

### Pattern 5: Nomad Variable Config

```hcl
template {
  data = <<-EOF
    {{ with nomadVar "nomad/jobs/myapp/config" }}
    FEATURE_FLAG_X={{ .feature_x }}
    LOG_LEVEL={{ .log_level }}
    {{ end }}
  EOF
  destination = "local/app.env"
  env         = true
  change_mode = "noop"   # don't restart, app reads at runtime
}
```

### Change Modes

| Mode | Behavior | Use Case |
|------|----------|----------|
| `restart` | Kill and restart the task | Secrets rotation, DB creds |
| `signal` | Send signal to task process | Config reload (nginx, HAProxy) |
| `noop` | Do nothing | App polls config file on its own |
| `script` | Run a script on change (v1.6+) | Custom validation before reload |

---

## Constraint and Affinity Strategies

### Constraints (Hard Requirements)

Constraints filter nodes — an allocation **cannot** be placed on a node that doesn't match.

```hcl
# Require specific kernel
constraint {
  attribute = "${attr.kernel.name}"
  value     = "linux"
}

# Require node class
constraint {
  attribute = "${node.class}"
  value     = "gpu"
}

# Require minimum kernel version
constraint {
  attribute = "${attr.kernel.version}"
  operator  = "version"
  value     = ">= 5.15"
}

# Require node metadata
constraint {
  attribute = "${meta.storage_type}"
  value     = "ssd"
}

# Distinct hosts — no two allocs on same node
constraint {
  operator = "distinct_hosts"
  value    = "true"
}

# Distinct property — spread across a property
constraint {
  operator = "distinct_property"
  attribute = "${node.datacenter}"
}
```

### Affinities (Soft Preferences)

Affinities influence placement scoring but don't prevent scheduling:

```hcl
# Prefer nodes with SSD storage (weight: -100 to 100)
affinity {
  attribute = "${meta.storage_type}"
  value     = "ssd"
  weight    = 75
}

# Prefer the newest kernel
affinity {
  attribute = "${attr.kernel.version}"
  operator  = "version"
  value     = ">= 6.0"
  weight    = 50
}

# Anti-affinity: avoid a specific datacenter
affinity {
  attribute = "${node.datacenter}"
  value     = "dc3"
  weight    = -50    # negative weight = avoid
}
```

### Strategy Guide

| Scenario | Use | Block |
|----------|-----|-------|
| Must run on Linux | Hard requirement | `constraint` |
| Must run on GPU nodes | Hard requirement | `constraint` |
| Prefer SSD nodes but can use HDD | Soft preference | `affinity` |
| One alloc per host max | Hard requirement | `constraint distinct_hosts` |
| Spread across AZs | Hard requirement | `constraint distinct_property` |
| Prefer us-east but tolerate eu-west | Soft preference | `affinity` with weight |

---

## Spread Scheduling

The `spread` stanza distributes allocations across a specified attribute (datacenter, availability zone, node pool) for resilience.

### Even Distribution

```hcl
group "api" {
  count = 6

  spread {
    attribute = "${node.datacenter}"
    # Without targets, Nomad distributes evenly across all values
  }
}
```

### Weighted Distribution

```hcl
spread {
  attribute = "${node.datacenter}"
  weight    = 100    # 0-100, higher = more influence on scoring

  target "dc1" { percent = 60 }
  target "dc2" { percent = 30 }
  target "dc3" { percent = 10 }
}
```

### Multi-Attribute Spread

```hcl
# Spread across datacenters
spread {
  attribute = "${node.datacenter}"
}

# Also spread across rack within each datacenter
spread {
  attribute = "${meta.rack}"
  weight    = 50
}
```

### Spread vs. Constraint distinct_property

- `spread`: Best-effort distribution, uses scoring. Tolerates imbalance if nodes are unavailable.
- `constraint distinct_property`: Hard requirement. Fails placement if the property can't be satisfied.

Use `spread` when you want resilience but can tolerate some imbalance. Use `distinct_property` when you **must** guarantee separation.

---

## Preemption

Preemption allows higher-priority jobs to evict lower-priority allocations when the cluster is resource-constrained.

### Enabling Preemption

```shell
# Enable for service, batch, and system schedulers
nomad operator scheduler set-config \
  -preempt-service-scheduler=true \
  -preempt-batch-scheduler=true \
  -preempt-sysbatch-scheduler=true
```

### Priority Levels

```hcl
job "critical-api" {
  priority = 90     # range: 1–100, higher = more important
  type     = "service"
  # ...
}

job "background-etl" {
  priority = 20
  type     = "batch"
  # ...
}
```

### How Preemption Works

1. High-priority job submitted but insufficient resources available.
2. Scheduler identifies lowest-priority allocations that could free enough resources.
3. Preempted allocations are evicted (rescheduled if possible).
4. High-priority job placed on freed resources.

### Preemption in `nomad job plan`

```shell
nomad job plan critical-api.nomad.hcl
# Output includes:
# Preemptions:
#   Alloc ID  Job             Task Group  Desired Status
#   abc123    background-etl  workers     evict
```

### Best Practices

- Reserve priority 100 for system-critical jobs only.
- Use priority bands: 80-100 (critical), 50-79 (production), 20-49 (development), 1-19 (best-effort).
- Monitor `nomad.nomad.plan.preemptions` metrics to detect resource pressure.
- Test preemption behavior in staging before enabling in production.
- Be cautious with batch preemption — evicted batch jobs lose progress unless they checkpoint.

---

## Device Plugins and GPU Scheduling

Nomad's device plugin framework exposes hardware accelerators (GPUs, FPGAs, TPUs) to the scheduler.

### NVIDIA GPU Plugin

The NVIDIA GPU plugin ships with Nomad. Enable on clients:

```hcl
plugin "nvidia-gpu" {
  config {
    enabled            = true
    fingerprint_period = "1m"
  }
}
```

### Requesting GPUs in Jobs

```hcl
task "train" {
  driver = "docker"

  config {
    image = "myorg/ml-training:latest"
    # GPU devices automatically passed to container
  }

  resources {
    cpu    = 4000
    memory = 8192

    device "nvidia/gpu" {
      count = 1

      # Request specific GPU model
      constraint {
        attribute = "${device.model}"
        value     = "Tesla V100"
      }

      # Or request minimum memory
      affinity {
        attribute = "${device.attr.memory}"
        operator  = ">="
        value     = "16384"    # 16 GB
        weight    = 80
      }
    }
  }
}
```

### Multi-GPU Jobs

```hcl
resources {
  device "nvidia/gpu" {
    count = 4    # request 4 GPUs on same node
  }
}
```

### Custom Device Plugins

Write plugins for non-GPU hardware (FPGAs, custom accelerators):

```go
// Implement the device.DevicePlugin interface
type MyPlugin struct {
    // ...
}

func (p *MyPlugin) Fingerprint(ctx context.Context) (<-chan *device.FingerprintResponse, error) {
    // Detect and report available devices
}

func (p *MyPlugin) Reserve(deviceIDs []string) (*device.ContainerReservation, error) {
    // Return environment variables and device mounts for the container
}
```

### Monitoring GPU Usage

```shell
# Check which nodes have GPUs
nomad node status -verbose <node-id> | grep -A5 "Device Resource"

# View GPU allocation
nomad alloc status <alloc-id> | grep -A5 "Device"
```

### Best Practices

- Use `constraint` on `${node.class}` to target GPU node pools, reducing scheduler work.
- Set `fingerprint_period` appropriately — too frequent wastes CPU, too infrequent delays detection.
- Monitor GPU utilization via DCGM exporter or `nvidia-smi` in a system job.
- Use affinities for GPU memory/model preferences, constraints for hard requirements.
- Consider preemption priorities: ML training (lower priority) should yield to inference (higher priority).
