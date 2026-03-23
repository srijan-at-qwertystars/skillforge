# Nomad Security Hardening Guide

## Table of Contents

- [ACL Bootstrapping](#acl-bootstrapping)
- [Token Management](#token-management)
- [Mutual TLS Setup](#mutual-tls-setup)
- [Gossip Encryption](#gossip-encryption)
- [Sentinel Policies](#sentinel-policies)
- [Namespace Isolation](#namespace-isolation)
- [Task Security](#task-security)
- [Vault Integration Security](#vault-integration-security)
- [Audit Logging](#audit-logging)
- [Network Segmentation](#network-segmentation)
- [Workload Identity](#workload-identity)
- [Hardening Checklist](#hardening-checklist)

---

## ACL Bootstrapping

ACLs are **off by default**. Without ACLs, any client with network access to Nomad can submit jobs, read secrets, and control the cluster.

### Enable ACLs

Add to **all** server and client configs:

```hcl
acl {
  enabled = true
}
```

Restart all servers first (rolling restart), then clients.

### Bootstrap the Management Token

```shell
# Run once on a server node
nomad acl bootstrap

# Output:
# Accessor ID  = <accessor>
# Secret ID    = <management-token>
# ...
```

**Critical**: Store the management token in a secure vault (HashiCorp Vault, AWS Secrets Manager, etc.). If lost, recovery requires the bootstrap reset procedure.

### Reset Bootstrap (Emergency)

If the management token is lost:

```shell
# On the leader server
echo '{}' > <data_dir>/server/acl-bootstrap-reset

# Then re-bootstrap
nomad acl bootstrap
```

### Lock Down Anonymous Access

Immediately after bootstrap, apply a restrictive anonymous policy:

```hcl
# anonymous-policy.hcl — deny everything by default
namespace "*" {
  policy = "deny"
}

node {
  policy = "deny"
}

agent {
  policy = "deny"
}

operator {
  policy = "deny"
}
```

```shell
nomad acl policy apply -description "Deny all anonymous access" anonymous anonymous-policy.hcl
```

---

## Token Management

### Token Types

| Type | Purpose | TTL |
|------|---------|-----|
| Management | Full cluster access | Never expires |
| Client | Scoped to policies | Configurable |
| Global | Replicated across regions | Configurable |

### Creating Scoped Tokens

```shell
# Create a CI/CD deploy token — limited to production namespace
nomad acl policy apply ci-deploy ci-deploy.hcl
nomad acl token create \
  -name="ci-deploy" \
  -policy="ci-deploy" \
  -type="client" \
  -ttl="24h"
```

**ci-deploy.hcl**:

```hcl
namespace "production" {
  policy       = "write"
  capabilities = ["submit-job", "read-job", "list-jobs", "read-logs"]
}

namespace "staging" {
  policy       = "write"
  capabilities = ["submit-job", "read-job", "list-jobs", "read-logs", "dispatch-job"]
}

node {
  policy = "read"
}
```

### Token Best Practices

1. **Use TTLs on all client tokens.** Never create non-expiring client tokens.
2. **One token per use case.** Don't share tokens across CI pipelines, operators, and services.
3. **Rotate tokens regularly.** Automate rotation via Vault's Nomad secrets engine.
4. **Revoke immediately** when a token is compromised:
   ```shell
   nomad acl token delete <accessor-id>
   ```
5. **Audit token usage.** Cross-reference API access logs with token accessor IDs.
6. **Use global tokens** only for multi-region operations. Default to local tokens.

### Vault-Managed Token Rotation

```shell
# Enable Vault's Nomad secrets engine
vault secrets enable nomad

# Configure Vault with Nomad management token
vault write nomad/config/access \
  address="https://nomad.example.com:4646" \
  token="<management-token>"

# Create a Vault role mapping to Nomad policies
vault write nomad/role/ci-deploy \
  policies="ci-deploy" \
  type="client" \
  ttl="1h" \
  max_ttl="24h"

# Generate ephemeral Nomad tokens from Vault
vault read nomad/creds/ci-deploy
```

---

## Mutual TLS Setup

mTLS encrypts all Nomad communication (HTTP API, RPC, Raft) and authenticates server/client identities.

### Certificate Requirements

You need:
1. **CA certificate** — trusted root.
2. **Server certificate** — per server, with SANs for server hostnames and IPs.
3. **Client certificate** — per client node.
4. **CLI certificate** — for operator `nomad` CLI access.

### Generate Certificates with cfssl

```shell
# Initialize CA
cfssl print-defaults csr | cfssl gencert -initca - | cfssljson -bare ca

# Server certificate (include all server hostnames/IPs as SANs)
echo '{
  "CN": "server.global.nomad",
  "hosts": [
    "server.global.nomad",
    "localhost",
    "127.0.0.1",
    "nomad-server-1.internal",
    "10.0.1.10"
  ],
  "key": { "algo": "ecdsa", "size": 256 },
  "names": [{ "O": "HashiCorp" }]
}' | cfssl gencert -ca=ca.pem -ca-key=ca-key.pem - | cfssljson -bare server

# Client certificate
echo '{
  "CN": "client.global.nomad",
  "hosts": ["client.global.nomad", "localhost", "127.0.0.1"],
  "key": { "algo": "ecdsa", "size": 256 },
  "names": [{ "O": "HashiCorp" }]
}' | cfssl gencert -ca=ca.pem -ca-key=ca-key.pem - | cfssljson -bare client
```

### Server TLS Configuration

```hcl
tls {
  http = true
  rpc  = true

  ca_file   = "/etc/nomad.d/tls/ca.pem"
  cert_file = "/etc/nomad.d/tls/server.pem"
  key_file  = "/etc/nomad.d/tls/server-key.pem"

  verify_server_hostname = true    # prevent impersonation attacks
  verify_https_client    = true    # require client certs for API access
}
```

### Client TLS Configuration

```hcl
tls {
  http = true
  rpc  = true

  ca_file   = "/etc/nomad.d/tls/ca.pem"
  cert_file = "/etc/nomad.d/tls/client.pem"
  key_file  = "/etc/nomad.d/tls/client-key.pem"

  verify_server_hostname = true
}
```

### CLI Configuration

```shell
export NOMAD_ADDR="https://nomad.example.com:4646"
export NOMAD_CACERT="/path/to/ca.pem"
export NOMAD_CLIENT_CERT="/path/to/cli.pem"
export NOMAD_CLIENT_KEY="/path/to/cli-key.pem"
```

### Certificate Rotation

1. Generate new certificates with the same CA (or a new CA if compromised).
2. Deploy new certs to all nodes.
3. Reload Nomad without restart: `nomad agent -config /etc/nomad.d/ -reload`.
4. If the CA changed, rolling restart is required.

**Automation**: Use Vault PKI secrets engine for automated certificate issuance and renewal.

---

## Gossip Encryption

Gossip encryption secures Serf communication between servers using a symmetric key.

### Generate Key

```shell
nomad operator gossip keyring generate
# Output: cg8StVXbQJ0gPvMd9o7VCg==
```

### Configure

Add to **all** server configs:

```hcl
server {
  enabled = true
  encrypt = "cg8StVXbQJ0gPvMd9o7VCg=="
}
```

### Key Rotation

```shell
# Install new key (all servers learn it)
nomad operator gossip keyring install "NEW_KEY_HERE"

# Switch to new key as primary
nomad operator gossip keyring use "NEW_KEY_HERE"

# Remove old key
nomad operator gossip keyring remove "OLD_KEY_HERE"
```

- Key rotation is live — no restarts needed.
- Always install before switching to avoid split-brain during rollout.

---

## Sentinel Policies

Sentinel (Enterprise) provides fine-grained policy-as-code enforcement on job submissions.

### Use Cases

- Restrict task drivers (e.g., block `raw_exec`).
- Enforce resource minimums/maximums.
- Require health checks on all services.
- Enforce image provenance (allowed registries).
- Block privileged containers.

### Example: Block raw_exec

```python
# block-raw-exec.sentinel
import "job"

main = rule {
  all job.task_groups as tg {
    all tg.tasks as task {
      task.driver is not "raw_exec"
    }
  }
}
```

### Example: Enforce Resource Limits

```python
# enforce-resources.sentinel
import "job"

max_memory = 4096  # MB
max_cpu    = 4000  # MHz

main = rule {
  all job.task_groups as tg {
    all tg.tasks as task {
      task.resources.memory_mb <= max_memory and
      task.resources.cpu <= max_cpu
    }
  }
}
```

### Example: Require Health Checks

```python
# require-health-checks.sentinel
import "job"

main = rule when job.type is "service" {
  all job.task_groups as tg {
    length(tg.services) > 0 and
    all tg.services as svc {
      length(svc.checks) > 0
    }
  }
}
```

### Example: Restrict Container Registries

```python
# allowed-registries.sentinel
import "job"
import "strings"

allowed_registries = [
  "myorg.jfrog.io/",
  "gcr.io/myproject/",
  "public.ecr.aws/myorg/",
]

main = rule {
  all job.task_groups as tg {
    all tg.tasks as task {
      task.driver is not "docker" or
      any allowed_registries as registry {
        strings.has_prefix(task.config.image, registry)
      }
    }
  }
}
```

### Applying Sentinel Policies

```shell
nomad sentinel apply -level=hard-mandatory block-raw-exec block-raw-exec.sentinel
nomad sentinel apply -level=soft-mandatory enforce-resources enforce-resources.sentinel
```

- **hard-mandatory**: Cannot be overridden. Blocks any non-conforming job.
- **soft-mandatory**: Can be overridden with `-policy-override` flag by privileged users.
- **advisory**: Logged but not enforced.

---

## Namespace Isolation

Namespaces provide logical multi-tenancy within a Nomad cluster.

### Creating Namespaces

```shell
nomad namespace apply -description "Production workloads" production
nomad namespace apply -description "Staging environment" staging
nomad namespace apply -description "Development sandbox" development
```

### Namespace-Scoped ACL Policies

```hcl
# team-frontend.hcl
namespace "production" {
  policy       = "read"
  capabilities = ["read-job", "list-jobs", "read-logs"]
}

namespace "staging" {
  policy       = "write"
  capabilities = ["submit-job", "read-job", "list-jobs", "dispatch-job", "read-logs"]
}

namespace "development" {
  policy       = "write"
  capabilities = ["submit-job", "read-job", "list-jobs", "dispatch-job", "read-logs", "alloc-exec"]
}
```

### Resource Quotas (Enterprise)

```shell
# Limit resources per namespace
nomad quota apply -description "Production limits" production-quota production-quota.hcl
```

```hcl
# production-quota.hcl
name = "production-quota"

limit {
  region = "global"
  region_limit {
    cpu        = 32000   # MHz
    memory     = 65536   # MB
  }
}
```

### Best Practices

- Default to `deny` for namespace access; explicitly grant per team.
- Use separate namespaces for CI/CD, production, staging, and development.
- Never let development namespace policies leak into production.
- Combine with Sentinel policies for defense in depth.

---

## Task Security

### Read-Only Root Filesystem

Prevent tasks from writing to the container filesystem (forces use of explicit volume mounts):

```hcl
task "app" {
  driver = "docker"

  config {
    image            = "myorg/app:v1"
    readonly_rootfs  = true

    # Explicitly mount writable directories
    volumes = [
      "local/tmp:/tmp",
    ]
  }
}
```

### No New Privileges

Prevent privilege escalation via `setuid`/`setgid` binaries:

```hcl
task "app" {
  driver = "docker"

  config {
    image = "myorg/app:v1"
    security_opt = ["no-new-privileges"]
  }
}
```

### Drop All Capabilities

```hcl
task "app" {
  driver = "docker"

  config {
    image = "myorg/app:v1"
    cap_drop = ["ALL"]
    cap_add  = ["NET_BIND_SERVICE"]   # only if needed
  }
}
```

### Non-Root User

```hcl
task "app" {
  user = "1000:1000"   # run as non-root UID:GID

  driver = "docker"
  config {
    image = "myorg/app:v1"
  }
}
```

### Resource Limits as Security

```hcl
resources {
  cpu        = 500     # prevent CPU starvation attacks
  memory     = 256     # prevent memory exhaustion
  memory_max = 512     # hard OOM limit
}

ephemeral_disk {
  size    = 500        # MB — prevent disk filling
  migrate = false
  sticky  = false
}
```

### Complete Hardened Task Example

```hcl
task "app" {
  driver = "docker"
  user   = "1000:1000"

  config {
    image           = "myorg/app:v1.2.3"   # pinned version, never :latest
    readonly_rootfs = true
    cap_drop        = ["ALL"]
    cap_add         = ["NET_BIND_SERVICE"]
    security_opt    = ["no-new-privileges"]
    pids_limit      = 100                   # prevent fork bombs

    volumes = [
      "local/tmp:/tmp",
      "secrets/config:/app/config:ro",
    ]
  }

  resources {
    cpu        = 500
    memory     = 256
    memory_max = 512
  }
}
```

---

## Vault Integration Security

### Workload Identity (Recommended — v1.7+)

Workload Identity eliminates long-lived Vault tokens. Nomad issues JWT tokens per allocation, and Vault validates them via JWKS:

```hcl
# Nomad server config
vault {
  enabled = true
  address = "https://vault.service.consul:8200"

  default_identity {
    aud  = ["vault.io"]
    ttl  = "1h"
    env  = false
    file = false
  }
}
```

```shell
# Vault config — JWT auth method
vault auth enable -path=jwt-nomad jwt

vault write auth/jwt-nomad/config \
  jwks_url="https://nomad.example.com:4646/.well-known/jwks.json" \
  default_role="nomad-workloads"

vault write auth/jwt-nomad/role/nomad-workloads \
  role_type="jwt" \
  bound_audiences="vault.io" \
  user_claim="/nomad_job_id" \
  user_claim_json_pointer=true \
  claim_mappings='{
    "nomad_namespace": "nomad_namespace",
    "nomad_job_id": "nomad_job_id",
    "nomad_task": "nomad_task"
  }' \
  token_type="service" \
  token_period="30m" \
  token_policies="nomad-workloads"
```

### Legacy Token-Based Integration

If using pre-1.7 or not using Workload Identity:

```hcl
vault {
  enabled          = true
  address          = "https://vault.service.consul:8200"
  token            = "<vault-token>"
  create_from_role = "nomad-cluster"
  tls_skip_verify  = false
}
```

**The `nomad-cluster` Vault role must be tightly scoped**:

```shell
# Vault policy for Nomad server
vault policy write nomad-server - <<EOF
path "auth/token/create/nomad-cluster" {
  capabilities = ["update"]
}
path "auth/token/roles/nomad-cluster" {
  capabilities = ["read"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/lookup" {
  capabilities = ["update"]
}
path "auth/token/revoke-accessor" {
  capabilities = ["update"]
}
path "sys/capabilities-self" {
  capabilities = ["update"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
EOF
```

### Task-Level Vault Policies

```hcl
task "app" {
  vault {
    policies    = ["app-secrets-read"]
    change_mode = "restart"
  }

  template {
    data = <<-EOF
      {{ with secret "secret/data/myapp/config" }}
      API_KEY={{ .Data.data.api_key }}
      {{ end }}
    EOF
    destination = "secrets/app.env"
    env         = true
  }
}
```

### Vault Security Best Practices

1. **Least-privilege policies**: Each task should only access the secrets it needs.
2. **Short TTLs**: Set `token_period` to 30 minutes or less.
3. **Never use root Vault token** in Nomad server config.
4. **Use `create_from_role`** to limit the server's token-creation scope.
5. **Enable Vault audit logging** to track all secret access.
6. **Separate Vault policies per namespace** — production tasks shouldn't access staging secrets.

---

## Audit Logging

### Enterprise Audit Logging

```hcl
audit {
  enabled = true

  sink "file" {
    type               = "file"
    delivery_guarantee = "enforced"     # block API calls if audit log fails
    format             = "json"
    path               = "/var/log/nomad/audit.json"
    rotate_bytes       = 104857600      # 100 MB
    rotate_duration    = "24h"
    rotate_max_files   = 30
  }
}
```

### OSS Audit Alternatives

For Nomad OSS (no built-in audit):

1. **Enable verbose logging** and ship to centralized logging:
   ```hcl
   log_level = "INFO"     # TRACE for deep debugging, but very noisy
   log_json  = true       # structured logging for parsing
   log_file  = "/var/log/nomad/nomad.log"
   log_rotate_bytes    = 104857600
   log_rotate_duration = "24h"
   log_rotate_max_files = 14
   ```

2. **API access logging** via reverse proxy (Nginx, HAProxy):
   ```nginx
   # Nginx reverse proxy logging
   server {
     listen 4646 ssl;
     location / {
       proxy_pass https://127.0.0.1:4647;
       access_log /var/log/nginx/nomad-api-access.log combined;
     }
   }
   ```

3. **Event stream** for real-time job events:
   ```shell
   curl -s "${NOMAD_ADDR}/v1/event/stream?topic=Job&topic=Evaluation&topic=Allocation" \
     -H "X-Nomad-Token: ${NOMAD_TOKEN}" | jq
   ```

### What to Log and Alert On

| Event | Severity | Action |
|-------|----------|--------|
| ACL token created/deleted | High | Alert immediately |
| Job submitted to production | Medium | Log and review |
| `raw_exec` job submitted | Critical | Alert and investigate |
| Failed authentication | High | Alert on >5 in 1 minute |
| Policy change | High | Alert immediately |
| Namespace creation | Medium | Log and review |
| Snapshot operations | Medium | Log for audit trail |

---

## Network Segmentation

### Required Ports

| Port | Protocol | Purpose | Access |
|------|----------|---------|--------|
| 4646 | TCP | HTTP API | Operators, CI/CD, load balancers |
| 4647 | TCP | RPC | Server-to-server, client-to-server |
| 4648 | TCP/UDP | Serf (gossip) | Server-to-server only |

### Firewall Rules

```shell
# Server-to-server (full mesh)
iptables -A INPUT -p tcp -s <server-subnet> --dport 4646:4648 -j ACCEPT
iptables -A INPUT -p udp -s <server-subnet> --dport 4648 -j ACCEPT

# Client-to-server (RPC only)
iptables -A INPUT -p tcp -s <client-subnet> --dport 4647 -j ACCEPT

# Operator access (API only, from bastion/VPN)
iptables -A INPUT -p tcp -s <operator-subnet> --dport 4646 -j ACCEPT

# Block all other Nomad traffic
iptables -A INPUT -p tcp --dport 4646:4648 -j DROP
iptables -A INPUT -p udp --dport 4648 -j DROP
```

### Network Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Operator VPN                          │
│  ┌──────────┐                                                │
│  │ Bastion  │──────── HTTPS (4646) ──────┐                   │
│  └──────────┘                             │                   │
├───────────────────────────────────────────┼──────────────────┤
│                    Server Subnet          │                   │
│  ┌──────────┐   ┌──────────┐   ┌─────────▼┐                 │
│  │ Server 1 │◄──│ Server 2 │◄──│ Server 3  │                 │
│  └────┬─────┘   └────┬─────┘   └────┬──────┘                │
│       │  RPC (4647)   │              │                        │
├───────┼───────────────┼──────────────┼───────────────────────┤
│       │         Client Subnet        │                        │
│  ┌────▼─────┐   ┌────▼─────┐   ┌────▼─────┐                 │
│  │ Client 1 │   │ Client 2 │   │ Client 3 │                 │
│  └──────────┘   └──────────┘   └──────────┘                 │
└─────────────────────────────────────────────────────────────┘
```

### Additional Segmentation

- **Separate server and client nodes physically** — never co-locate in production.
- **Use security groups/VPC** in cloud environments instead of host-level iptables.
- **Restrict outbound** from client nodes to only required services (registries, Consul, Vault).
- **Isolate workload traffic** using Consul Connect service mesh — workloads communicate over mTLS, not raw TCP.

---

## Workload Identity

Workload Identity (v1.7+) assigns a unique JWT to each allocation, enabling zero-trust authentication to external services without pre-shared secrets.

### How It Works

1. Nomad server issues a signed JWT for each running allocation.
2. The JWT contains claims: `nomad_namespace`, `nomad_job_id`, `nomad_task`, `nomad_alloc_id`.
3. External services (Vault, AWS, GCP, custom APIs) validate the JWT using Nomad's JWKS endpoint.

### Configuration

```hcl
# Server config
server {
  default_identity {
    aud  = ["vault.io", "aws.amazon.com"]
    ttl  = "1h"
    env  = true     # expose as NOMAD_TOKEN env var in tasks
    file = true     # write to secrets/nomad_token file
  }
}
```

### Task-Level Identity Override

```hcl
task "app" {
  identity {
    env  = true
    file = true
    ttl  = "30m"

    change_mode   = "restart"
    change_signal = "SIGHUP"
  }
}
```

### JWKS Endpoint

```shell
# Nomad exposes public keys for JWT verification
curl -s "https://nomad.example.com:4646/.well-known/jwks.json" | jq
```

### Integration with AWS IAM

```shell
# Create OIDC provider in AWS
aws iam create-open-id-connect-provider \
  --url "https://nomad.example.com:4646" \
  --client-id-list "aws.amazon.com" \
  --thumbprint-list "<tls-thumbprint>"

# Create IAM role trusting Nomad workload identity
# Trust policy references the OIDC provider and Nomad claims
```

---

## Hardening Checklist

### Mandatory (All Environments)

- [ ] ACLs enabled with restrictive anonymous policy
- [ ] Management token stored securely (not in config files)
- [ ] mTLS enabled on all HTTP and RPC communication
- [ ] `verify_server_hostname = true` on all nodes
- [ ] Gossip encryption enabled on all servers
- [ ] Nomad servers and clients on separate nodes
- [ ] Server and client data directories have restrictive permissions (`0700`)
- [ ] Nomad runs as a dedicated non-root user (or root with dropped privileges)
- [ ] All tokens have TTLs (no indefinite client tokens)
- [ ] Network access to Nomad ports restricted by firewall

### Recommended (Production)

- [ ] `verify_https_client = true` on servers (require client certs for API)
- [ ] Vault integration uses Workload Identity (not long-lived tokens)
- [ ] Namespaces configured per team/environment
- [ ] Resource quotas enforced per namespace (Enterprise)
- [ ] Sentinel policies block `raw_exec` and privileged containers (Enterprise)
- [ ] Audit logging enabled and shipped to centralized store
- [ ] Certificate rotation automated via Vault PKI
- [ ] Gossip key rotation scheduled quarterly
- [ ] Monitoring alerts on failed auth attempts and policy changes
- [ ] `log_json = true` for machine-parseable logs

### Task-Level (Per Job)

- [ ] Tasks run as non-root user
- [ ] `readonly_rootfs = true` where possible
- [ ] `security_opt = ["no-new-privileges"]`
- [ ] `cap_drop = ["ALL"]` with explicit `cap_add` only as needed
- [ ] Container images pinned to digest or specific version tag (never `:latest`)
- [ ] Vault policies scoped to minimum required secrets
- [ ] Resources (CPU, memory, disk) explicitly set
- [ ] Health checks defined on all services
