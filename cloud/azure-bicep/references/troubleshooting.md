# Azure Bicep Troubleshooting Guide

## Table of Contents
- [Deployment Failures](#deployment-failures)
  - [ResourceNotFound](#resourcenotfound)
  - [InvalidTemplate / InvalidTemplateDeployment](#invalidtemplate--invalidtemplatedeployment)
  - [AuthorizationFailed](#authorizationfailed)
  - [RequestDisallowedByPolicy](#requestdisallowedbypolicy)
  - [DeploymentQuotaExceeded](#deploymentquotaexceeded)
- [Module Resolution Errors](#module-resolution-errors)
- [Circular Dependencies](#circular-dependencies)
- [What-If False Positives](#what-if-false-positives)
- [Linter Rule Suppression](#linter-rule-suppression)
- [ARM → Bicep Decompilation Issues](#arm--bicep-decompilation-issues)
- [API Version Compatibility](#api-version-compatibility)
- [Debugging Techniques](#debugging-techniques)

---

## Deployment Failures

### ResourceNotFound

**Error:** `The Resource 'Microsoft.xxx/yyy/zzz' under resource group 'rg' was not found.`

**Causes & fixes:**

| Cause | Fix |
|---|---|
| Resource not yet created when referenced | Bicep usually infers deps from symbolic refs — ensure you reference via symbolic name, not string ID |
| `existing` resource doesn't exist | Verify name/RG/subscription. Use `az resource show` to confirm |
| Wrong scope on `existing` resource | Add `scope: resourceGroup('correct-sub', 'correct-rg')` |
| Child resource before parent completes | Use `parent:` property instead of name-concatenation |
| Timing issue with eventual consistency | Add `dependsOn` explicitly (rare — only for non-symbolic refs) |

```bicep
// BAD: string-based ref loses dependency tracking
resource subnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  name: '${vnetName}/mySubnet'   // Bicep can't infer dependency
  properties: { addressPrefix: '10.0.1.0/24' }
}

// GOOD: symbolic parent reference
resource subnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: vnet                    // dependency auto-inferred
  name: 'mySubnet'
  properties: { addressPrefix: '10.0.1.0/24' }
}
```

### InvalidTemplate / InvalidTemplateDeployment

**Error:** `The template deployment 'xxx' is not valid.` or inner errors like `InvalidParameter`, `PropertyChangeNotAllowed`.

**Diagnostic steps:**
```bash
# Get detailed error
az deployment group show -g myRg -n deploymentName \
  --query "properties.error" -o json

# Validate without deploying
az deployment group validate -g myRg \
  --template-file main.bicep --parameters @params.json

# Build to ARM JSON and inspect
bicep build main.bicep --outfile debug.json
```

**Common causes:**

| Cause | Fix |
|---|---|
| Wrong parameter type | Check `param` declaration matches passed value type |
| Missing required parameter | Supply all params without defaults |
| Invalid API version | Update to supported version (see [API Version Compatibility](#api-version-compatibility)) |
| Immutable property change | Delete & recreate, or use a new resource name |
| Expression evaluation error | Simplify; check `null` vs missing values |
| Array where object expected | Fix parameter value shape in `.bicepparam` or JSON |

### AuthorizationFailed

**Error:** `The client 'xxx' with object id 'yyy' does not have authorization to perform action 'zzz' over scope '/subscriptions/...'`

**Diagnostic steps:**
```bash
# Check current identity
az account show --query "{user:user.name, subscription:name}"

# Check role assignments
az role assignment list --assignee <objectId> --scope /subscriptions/<subId> -o table

# Check resource provider registration
az provider show --namespace Microsoft.Storage --query "registrationState"

# Register missing provider
az provider register --namespace Microsoft.ContainerService
```

**Common causes:**

| Cause | Fix |
|---|---|
| Identity lacks RBAC role | Assign `Contributor` or a custom role at the correct scope |
| Resource provider not registered | `az provider register --namespace Microsoft.Xxx` |
| Cross-subscription deployment | Ensure identity has roles in target subscription |
| Deployment stack deny settings blocking | Add principal to `excludedPrincipals` in stack |
| PIM role not activated | Activate the role before deploying |

### RequestDisallowedByPolicy

**Error:** `Resource 'xxx' was disallowed by policy.`

```bash
# Find which policy blocked it
az policy assignment list --scope /subscriptions/<subId> -o table

# Check specific policy details
az policy assignment show --name <assignmentName> --query "properties.displayName"
```

**Fix:** Comply with policy requirements (tags, SKUs, regions, etc.) or request an exemption.

### DeploymentQuotaExceeded

**Error:** `Creating the deployment would exceed the quota of 800.`

```bash
# List and clean old deployments
az deployment group list -g myRg --query "length(@)"
az deployment group list -g myRg --filter "provisioningState eq 'Failed'" \
  --query "[].name" -o tsv | xargs -I{} az deployment group delete -g myRg -n {}
```

---

## Module Resolution Errors

**Error:** `Unable to restore module` / `Module not found` / `Registry authentication failed`

| Scenario | Fix |
|---|---|
| Local module not found | Check relative path — must be from consuming file's directory |
| Registry module auth failure | `az acr login --name myacr` or check service principal has `AcrPull` |
| Registry module not found | Verify exact path and version: `br:myacr.azurecr.io/path/name:version` |
| Template spec not found | Verify subscription ID, resource group, spec name, and version |
| Alias misconfigured | Check `bicepconfig.json` `moduleAliases` section |
| Version doesn't exist | List versions: `az acr repository show-tags --name myacr --repository bicep/modules/storage` |

```bash
# Restore all external modules
bicep restore main.bicep

# Verify registry access
az acr repository list --name myacr -o table

# List module versions
az acr repository show-tags --name myacr --repository bicep/modules/storage -o table

# Check bicepconfig.json alias
cat bicepconfig.json | jq '.moduleAliases'
```

**Tip:** Always pin module versions. Never use `:latest` — it prevents reproducible deployments.

---

## Circular Dependencies

**Error:** `Circular dependency detected` in Bicep compilation or ARM deployment.

**Detection:**
```bash
# Bicep will error at build time
bicep build main.bicep
# Error: A cycle was detected in the references: resourceA -> resourceB -> resourceA
```

**Common patterns and fixes:**

### Pattern 1: Mutual resource references
```bicep
// BAD: A references B, B references A
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'myNsg'
  properties: { subnets: [{ id: subnet.id }] }  // refs subnet
}
resource subnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  properties: { networkSecurityGroup: { id: nsg.id } }  // refs NSG → cycle!
}

// GOOD: Only one direction — associate NSG from subnet side
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'myNsg'
  location: location
  properties: {}
}
resource subnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: vnet
  name: 'mySubnet'
  properties: {
    addressPrefix: '10.0.1.0/24'
    networkSecurityGroup: { id: nsg.id }  // one-way ref
  }
}
```

### Pattern 2: Module output fed back as input
```bicep
// GOOD: Break cycle with a third module or deployment script
module step1 './step1.bicep' = { name: 'step1', params: { ... } }
module step2 './step2.bicep' = { name: 'step2', params: { id: step1.outputs.id } }
// Don't have step1 depend on step2's output
```

### Pattern 3: Key Vault + App Service secret
```bicep
// BAD: KV needs app identity, app needs KV URI → cycle
// GOOD: Use existing KV or split into two deployments
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' existing = { name: kvName }
resource app 'Microsoft.Web/sites@2023-12-01' = {
  name: appName
  identity: { type: 'SystemAssigned' }
  properties: {
    siteConfig: {
      appSettings: [{ name: 'KV_URI', value: kv.properties.vaultUri }]
    }
  }
}
// Access policy in separate resource (no cycle)
resource kvAccess 'Microsoft.KeyVault/vaults/accessPolicies@2023-07-01' = {
  parent: kv
  name: 'add'
  properties: { accessPolicies: [{ objectId: app.identity.principalId, ... }] }
}
```

---

## What-If False Positives

What-if commonly reports spurious changes. Known scenarios:

| False Positive | Reason |
|---|---|
| `provisioningState` shown as modified | Read-only property, always in diff |
| Tags shown as modified with same values | Case sensitivity or ordering differences |
| `Modify` on conditional resources | What-if evaluates both branches |
| `Deploy` for no-change resources | ARM can't detect certain property equality |
| Secret values shown as changed | Values masked, comparison fails |
| `Ignore` for extension resources | Not all types support what-if |

**Mitigation strategies:**
- Use `--result-format FullResourcePayloads` to see actual property diffs
- Build CI gates that only block on `Delete` and `Create`, not `Modify`
- Document known false positives in your pipeline README
- Compare what-if JSON output against a baseline:
```bash
az deployment group what-if -g myRg --template-file main.bicep -o json \
  | jq '[.changes[] | select(.changeType != "NoChange" and .changeType != "Ignore")]'
```

---

## Linter Rule Suppression

### Inline suppression
```bicep
// Suppress single rule on next line
#disable-next-line no-hardcoded-location
resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  location: 'eastus'  // justified: single-region compliance
  // ...
}

// Suppress multiple rules
#disable-next-line no-hardcoded-location no-hardcoded-env-urls
```

### bicepconfig.json rule levels
```json
{
  "analyzers": {
    "core": {
      "rules": {
        "no-unused-params": { "level": "off" },      // off | warning | error
        "no-hardcoded-location": { "level": "warning" },
        "explicit-values-for-loc-params": { "level": "warning" },
        "max-outputs": { "level": "warning" },
        "max-params": { "level": "warning" },
        "max-resources": { "level": "warning" },
        "max-variables": { "level": "warning" },
        "no-deployments-resources": { "level": "warning" }
      }
    }
  }
}
```

**All built-in linter rules:** `adminusername-should-not-be-literal`, `artifacts-parameters`, `decompiler-cleanup`, `explicit-values-for-loc-params`, `max-outputs`, `max-params`, `max-resources`, `max-variables`, `nested-deployment-template-scoping`, `no-conflicting-metadata`, `no-deployments-resources`, `no-hardcoded-env-urls`, `no-hardcoded-location`, `no-loc-expr-outside-params`, `no-unnecessary-dependson`, `no-unused-existing-resources`, `no-unused-params`, `no-unused-vars`, `outputs-should-not-contain-secrets`, `prefer-interpolation`, `prefer-unquoted-property-names`, `protect-commandtoexecute-secrets`, `secure-params-in-nested-deploy`, `secure-parameter-default`, `simplify-interpolation`, `simplify-json-null`, `use-parent-property`, `use-recent-api-versions`, `use-resource-id-functions`, `use-resource-symbol-reference`, `use-safe-access`, `use-stable-resource-identifiers`, `use-stable-vm-image`, `what-if-short-circuit-evaluation`.

---

## ARM → Bicep Decompilation Issues

```bash
bicep decompile template.json
# Produces template.bicep with warnings
```

**Common issues:**

| Issue | Fix |
|---|---|
| `WARNING: unresolvable reference` | Replace `reference()` with symbolic resource name |
| Nested deployments become complex modules | Flatten manually; extract to separate module files |
| `concat()` calls everywhere | Replace with string interpolation `'${a}-${b}'` |
| `copyIndex()` loops | Rewrite as `for` loops |
| Unnecessary `dependsOn` | Remove — Bicep infers from symbolic references |
| `variables` with complex expressions | Simplify or convert to user-defined functions |
| Missing type safety | Add `@allowed()`, `@minLength()`, `@secure()` decorators |
| `resourceId()` calls | Replace with `resource.id` symbolic reference |
| Condition expressions | Simplify `if()` to Bicep `?:` ternary |

**Post-decompilation checklist:**
1. `bicep build` — verify it compiles
2. Remove all `dependsOn` that Bicep can infer
3. Replace `concat()` with interpolation
4. Replace `reference()` / `resourceId()` with symbolic refs
5. Add `@description()` to all params
6. Run `bicep lint` and fix warnings
7. Extract repeated resources into modules
8. Test with `what-if` before deploying

---

## API Version Compatibility

### Finding valid API versions
```bash
# List available API versions for a resource type
az provider show --namespace Microsoft.Storage \
  --query "resourceTypes[?resourceType=='storageAccounts'].apiVersions[]" -o tsv

# VS Code Bicep extension shows available versions via IntelliSense

# Check if API version is valid for your region
az provider show --namespace Microsoft.ContainerService \
  --query "resourceTypes[?resourceType=='managedClusters'].{versions:apiVersions, locations:locations}"
```

### API version best practices
- **Pin stable versions** — avoid `-preview` in production
- **Use recent stable versions** — linter rule `use-recent-api-versions` helps
- **Don't mix versions** for parent/child resources of the same type
- **Update periodically** — old versions get deprecated (12+ months notice)

### Common version issues

| Symptom | Cause | Fix |
|---|---|---|
| `NoRegisteredProviderFound` | API version not available in region | Use an older stable version or different region |
| `InvalidApiVersionParameter` | Version doesn't exist for this resource type | Check valid versions with `az provider show` |
| `PropertyNotAllowed` | New property used with old API version | Upgrade API version |
| `MissingRequiredProperty` | Newer API version requires additional properties | Add required properties or use older version |

---

## Debugging Techniques

### Verbose deployment logging
```bash
# Deploy with debug output
az deployment group create -g myRg --template-file main.bicep \
  --parameters @params.json --debug 2>&1 | tee deploy-debug.log

# Get deployment operations (shows per-resource status)
az deployment operation group list -g myRg -n deploymentName -o table

# Get failed operations detail
az deployment operation group list -g myRg -n deploymentName \
  --query "[?properties.provisioningState=='Failed'].{resource:properties.targetResource.resourceType, error:properties.statusMessage.error}" -o json
```

### Build and inspect ARM output
```bash
# See what ARM JSON Bicep generates
bicep build main.bicep --outfile debug.json
cat debug.json | jq '.resources[].type'

# Diff two versions
bicep build v1/main.bicep --outfile v1.json
bicep build v2/main.bicep --outfile v2.json
diff <(jq -S . v1.json) <(jq -S . v2.json)
```

### Activity log queries
```bash
# Find deployment errors in Activity Log
az monitor activity-log list --resource-group myRg \
  --status Failed --offset 1h -o table

# Correlate with correlation ID from error
az monitor activity-log list --correlation-id <id> -o json
```

### Common debugging flow
1. `bicep lint main.bicep` — catch issues pre-deploy
2. `az deployment group validate` — ARM-level validation
3. `az deployment group what-if` — preview changes
4. Deploy with `--debug` flag if failures occur
5. Check `az deployment operation group list` for per-resource errors
6. Review Activity Log for additional context
