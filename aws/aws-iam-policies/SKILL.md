---
name: aws-iam-policies
description:
  positive: "Use when user writes AWS IAM policies, asks about IAM roles, trust policies, permission boundaries, SCPs, IAM conditions, cross-account access, OIDC federation, or IAM Access Analyzer."
  negative: "Do NOT use for AWS networking (VPC/SG), Kubernetes RBAC, or general OAuth/OIDC without AWS IAM context."
---

# AWS IAM Policies & Access Management

## IAM Fundamentals

### Principals
- **Root account** — full access, never use for daily operations.
- **IAM users** — long-lived credentials bound to one person or application. Prefer roles instead.
- **IAM roles** — assumable identity with temporary credentials. Use for services, cross-account, and federation.
- **IAM groups** — attach policies to groups, assign users to groups. Groups cannot be principals in resource policies.
- **Federated users** — external identities (SAML, OIDC, IAM Identity Center) that assume roles.

### Policy Evaluation Logic
1. All requests start as implicit deny.
2. Evaluate all applicable policies (identity-based, resource-based, SCPs, permission boundaries, session policies).
3. An explicit `Deny` in any policy overrides any `Allow`.
4. An `Allow` is required from an applicable policy to grant access.
5. For cross-account access: both the resource policy AND the caller's identity policy must allow (unless resource policy grants directly to the caller's principal ARN).

## Policy Language

Every IAM policy statement contains these elements:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DescriptiveStatementId",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::my-bucket",
        "arn:aws:s3:::my-bucket/*"
      ],
      "Condition": {
        "StringEquals": {
          "aws:PrincipalOrgID": "o-abc123"
        }
      }
    }
  ]
}
```

### Key Elements
- **Effect** — `Allow` or `Deny`. Always explicit.
- **Action** — API operations (`s3:GetObject`). Supports wildcards (`s3:Get*`).
- **Resource** — ARNs the statement applies to. Use specific ARNs, not `"*"`.
- **Condition** — Optional constraints (IP, tags, org, region, MFA).
- **Principal** — Who the policy applies to (resource-based and trust policies only).
- **NotAction** — Matches everything except listed actions. Use with `Deny` to block everything except specified actions.
- **NotResource** — Matches everything except listed resources. Dangerous—prefer explicit `Resource` lists.

### NotAction Pattern — Allow All Except
```json
{
  "Effect": "Deny",
  "NotAction": ["iam:ChangePassword", "iam:GetAccountPasswordPolicy"],
  "Resource": "*",
  "Condition": {
    "BoolIfExists": {"aws:MultiFactorAuthPresent": "false"}
  }
}
```
Deny everything except password changes when MFA is not present.

## Policy Types

### Identity-Based Policies
Attach to users, groups, or roles. Define what the principal can do.
- **AWS managed** — maintained by AWS (e.g., `ReadOnlyAccess`). Broad; review before using.
- **Customer managed** — you own and maintain. Prefer these for production roles.
- **Inline** — embedded directly in a principal. Avoid; hard to audit and reuse.

### Resource-Based Policies
Attach to resources (S3 buckets, SQS queues, KMS keys, Lambda functions). Specify who can access the resource.
```json
{
  "Effect": "Allow",
  "Principal": {"AWS": "arn:aws:iam::123456789012:role/CrossAccountRole"},
  "Action": "s3:GetObject",
  "Resource": "arn:aws:s3:::shared-bucket/*"
}
```

### Service Control Policies (SCPs)
Apply to AWS Organizations OUs/accounts. Set maximum available permissions. Do not grant permissions—only restrict.

### Permission Boundaries
Set maximum permissions for IAM users/roles. Effective permissions = intersection of identity policy AND permission boundary.

### Session Policies
Passed during `AssumeRole`, `GetFederationToken`, or federation. Further restrict the session below the role's identity policy.

## Least Privilege Patterns

### IAM Access Analyzer
- **Policy generation**: Analyze CloudTrail logs (up to 90 days) to generate policies based on actual API usage.
- **Unused access analyzer**: Detect unused roles, users, permissions, and access keys across the organization.
- **Policy validation**: Check policies for errors, security warnings, and suggestions before deployment.
- **External access findings**: Identify resources shared with external principals.

```bash
# Generate policy from CloudTrail activity
aws accessanalyzer start-policy-generation \
  --policy-generation-details '{"principalArn":"arn:aws:iam::123456789012:role/MyRole"}'

# List unused access findings
aws accessanalyzer list-findings --analyzer-arn <analyzer-arn> \
  --filter '{"status":{"eq":["ACTIVE"]}}'
```

### Iterative Refinement Workflow
1. Start with AWS managed policy or broad permissions in dev.
2. Enable CloudTrail logging.
3. Run Access Analyzer policy generation after 30–90 days.
4. Replace broad policy with generated least-privilege policy.
5. Use Access Advisor (last-accessed data) to identify unused services.
6. Monitor and repeat quarterly.

## Condition Keys

### Common Global Condition Keys
```json
{
  "Condition": {
    "IpAddress": {"aws:SourceIp": "203.0.113.0/24"},
    "StringEquals": {
      "aws:PrincipalOrgID": "o-abc123",
      "aws:RequestedRegion": ["us-east-1", "eu-west-1"]
    },
    "StringLike": {
      "aws:PrincipalTag/Department": "Engineering*"
    },
    "Bool": {"aws:MultiFactorAuthPresent": "true"},
    "NumericLessThan": {"aws:MultiFactorAuthAge": "3600"},
    "ArnLike": {
      "aws:SourceArn": "arn:aws:sns:us-east-1:123456789012:my-topic"
    }
  }
}
```

### Tag-Based Access Control (ABAC)
Grant access based on matching tags between principal and resource:
```json
{
  "Effect": "Allow",
  "Action": ["ec2:StartInstances", "ec2:StopInstances"],
  "Resource": "*",
  "Condition": {
    "StringEquals": {
      "aws:ResourceTag/Project": "${aws:PrincipalTag/Project}",
      "aws:ResourceTag/Environment": "${aws:PrincipalTag/Environment}"
    }
  }
}
```
ABAC scales better than RBAC—add new projects by tagging resources, no policy changes needed.

### Condition Operators
- `StringEquals` / `StringNotEquals` — exact match.
- `StringLike` / `StringNotLike` — supports `*` and `?` wildcards.
- `ArnLike` / `ArnEquals` — ARN matching with/without wildcards.
- `IpAddress` / `NotIpAddress` — CIDR range matching.
- `DateGreaterThan` / `DateLessThan` — time-based restrictions.
- `Null` — check if a condition key exists (`"aws:TokenIssueTime": "true"` means key is absent).

## Cross-Account Access

### Role Assumption Pattern
Account A (trusting) creates a role with trust policy:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"AWS": "arn:aws:iam::999888777666:root"},
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": {"sts:ExternalId": "unique-external-id-here"}
    }
  }]
}
```
Account B (trusted) grants `sts:AssumeRole` permission to its users/roles for the target role ARN.

Use `ExternalId` to prevent confused deputy attacks when third parties assume roles.

### Organization-Wide Access
Restrict resource sharing to your organization only:
```json
{
  "Effect": "Deny",
  "Action": "s3:*",
  "Resource": "arn:aws:s3:::sensitive-bucket/*",
  "Condition": {
    "StringNotEquals": {"aws:PrincipalOrgID": "o-abc123"}
  }
}
```

### Organization Path Conditions
Scope access to specific OUs:
```json
{
  "Condition": {
    "ForAnyValue:StringLike": {
      "aws:PrincipalOrgPaths": "o-abc123/r-root/ou-prod/*"
    }
  }
}
```

## IAM Roles for Services

### EC2 Instance Profiles
Attach an instance profile (wrapping a role) to EC2 instances. Applications use the instance metadata service (IMDS) to get temporary credentials.
- Always use IMDSv2 (require token-based metadata requests).
- Never embed access keys in EC2 instances.

### Lambda Execution Roles
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ],
    "Resource": "arn:aws:logs:us-east-1:123456789012:log-group:/aws/lambda/my-function:*"
  }]
}
```
Grant only the permissions the function needs. Scope log group ARN to the specific function.

### ECS Task Roles
- **Task role** — permissions for the application running in the container.
- **Task execution role** — permissions for ECS agent to pull images and write logs.
- Separate these roles. Never combine task and execution permissions.

## OIDC Federation

### GitHub Actions Trust Policy
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:my-org/my-repo:ref:refs/heads/main"
      }
    }
  }]
}
```
- Lock `sub` to specific repo, branch, or environment.
- Never use wildcard `*` for the `sub` claim in production.
- GitHub workflow needs `permissions: { id-token: write }`.

### Kubernetes (EKS) IRSA
Associate Kubernetes service accounts with IAM roles via the EKS OIDC provider. Trust policy scopes to namespace and service account:
```json
{
  "Condition": {
    "StringEquals": {
      "oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE:sub":
        "system:serviceaccount:my-namespace:my-service-account",
      "oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE:aud":
        "sts.amazonaws.com"
    }
  }
}
```
Use EKS Pod Identity as the newer alternative to IRSA for simplified setup.

## IAM Identity Center (SSO)

### Core Concepts
- **Identity source** — AWS directory, Active Directory, or external IdP (Okta, Entra ID, Google).
- **Permission sets** — collections of policies assigned to users/groups for specific accounts.
- **Account assignments** — bind permission set + user/group to an AWS account.

### Permission Set Design
- Keep permission sets simple (`ReadOnly`, `PowerUser`, `Admin`).
- Use ABAC conditions within permission sets for granularity.
- Prefer customer managed policies within permission sets over inline policies.

### ABAC with Identity Center
Pass user attributes (department, team, cost center) as session tags from IdP:
```json
{
  "Effect": "Allow",
  "Action": "ec2:*",
  "Resource": "*",
  "Condition": {
    "StringEquals": {
      "aws:ResourceTag/Team": "${aws:PrincipalTag/Team}"
    }
  }
}
```
Change access by updating user attributes in the IdP—no AWS policy changes required.

## Service Control Policies

### Region Restriction
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyOutsideApprovedRegions",
    "Effect": "Deny",
    "NotAction": [
      "iam:*",
      "sts:*",
      "organizations:*",
      "support:*",
      "budgets:*"
    ],
    "Resource": "*",
    "Condition": {
      "StringNotEquals": {
        "aws:RequestedRegion": ["us-east-1", "eu-west-1"]
      }
    }
  }]
}
```
Use `NotAction` to exclude global services (IAM, STS, Organizations) from region restrictions.

### Protect Security Services
```json
{
  "Sid": "DenyDisablingSecurityServices",
  "Effect": "Deny",
  "Action": [
    "guardduty:DeleteDetector",
    "guardduty:DisassociateFromMasterAccount",
    "cloudtrail:StopLogging",
    "cloudtrail:DeleteTrail",
    "config:StopConfigurationRecorder",
    "config:DeleteConfigurationRecorder"
  ],
  "Resource": "*"
}
```

### SCP Design Rules
- SCPs do not grant permissions—only restrict the maximum available.
- Apply to member accounts, never the management account.
- Test in a sandbox OU before applying to production.
- Use `Deny` with conditions rather than `Allow` lists for easier maintenance.
- Exempt automation roles using condition keys: `"StringNotLike": {"aws:PrincipalArn": "arn:aws:iam::*:role/OrgAdminRole"}`.

## Permission Boundaries

### Delegation Pattern
Allow developers to create roles without privilege escalation:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCreateRoleWithBoundary",
      "Effect": "Allow",
      "Action": ["iam:CreateRole", "iam:AttachRolePolicy"],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "iam:PermissionsBoundary": "arn:aws:iam::123456789012:policy/DeveloperBoundary"
        }
      }
    },
    {
      "Sid": "DenyBoundaryModification",
      "Effect": "Deny",
      "Action": [
        "iam:DeleteRolePermissionsBoundary",
        "iam:PutRolePermissionsBoundary"
      ],
      "Resource": "*"
    }
  ]
}
```
- Require a permission boundary on every role the developer creates.
- Deny removal or modification of the boundary.
- The boundary limits maximum permissions regardless of attached policies.

## Policy Troubleshooting

### Simulate Permissions
```bash
# Test if a principal can perform an action
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::123456789012:role/MyRole \
  --action-names s3:GetObject \
  --resource-arns arn:aws:s3:::my-bucket/key.txt
```

### CloudTrail Analysis
- Search CloudTrail for `AccessDenied` or `UnauthorizedOperation` errors.
- The `errorCode` and `errorMessage` fields identify the denied action.
- Check `userIdentity` to confirm which principal made the request.

### Access Advisor
```bash
# Check last-accessed services for a role
aws iam generate-service-last-accessed-details \
  --arn arn:aws:iam::123456789012:role/MyRole
```
Use last-accessed data to identify and remove permissions for services the role never uses.

### Common Denial Causes
1. Missing `Allow` in identity or resource policy.
2. Explicit `Deny` in SCP, permission boundary, or session policy.
3. Wrong resource ARN (missing trailing `/*` for S3 objects vs bucket).
4. Condition key mismatch (case sensitivity, missing tag).
5. Cross-account: resource policy missing OR identity policy missing.
6. Service-linked role requirements not met.

## Security Patterns

### MFA Enforcement
```json
{
  "Sid": "DenyAllExceptMFAManagementWithoutMFA",
  "Effect": "Deny",
  "NotAction": [
    "iam:CreateVirtualMFADevice",
    "iam:EnableMFADevice",
    "iam:ListMFADevices",
    "iam:ResyncMFADevice",
    "sts:GetSessionToken"
  ],
  "Resource": "*",
  "Condition": {
    "BoolIfExists": {"aws:MultiFactorAuthPresent": "false"}
  }
}
```

### Root Account Protection
- Enable MFA on root. Use hardware MFA for production.
- Do not create access keys for root.
- Use SCP to deny all root actions except break-glass scenarios.
- Monitor root login with CloudWatch Events / EventBridge.

### Key Rotation
- Rotate IAM access keys every 90 days maximum.
- Use `aws iam list-access-keys` and `aws iam get-access-key-last-used` to audit.
- Prefer temporary credentials (roles, Identity Center) over access keys entirely.

## Anti-Patterns — Avoid These

| Anti-Pattern | Why It's Dangerous | Do Instead |
|---|---|---|
| `"Action": "*"` on `"Resource": "*"` | Grants full admin; one compromise = total breach | Scope to specific actions and ARNs |
| Inline policies | Hard to audit, cannot reuse, no versioning | Use customer managed policies |
| Long-lived access keys | Keys leak in code, logs, config files | Use IAM roles with temporary credentials |
| Sharing IAM users | No individual accountability | One IAM user or federated identity per person |
| `NotResource` in Allow | Can unintentionally grant access to new resources | Use explicit `Resource` ARN lists |
| Wildcard principal (`"*"`) in resource policy without conditions | Public access to the resource | Add `aws:PrincipalOrgID` or specific principal ARN |
| Attaching `AdministratorAccess` to service roles | Massive blast radius | Scope to exact API actions the service needs |
| Ignoring Access Analyzer findings | Unused permissions accumulate | Review findings monthly, act on recommendations |

<!-- tested: pass -->
