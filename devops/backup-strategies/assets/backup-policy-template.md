# Backup Policy Document

> Template for organizational backup policy. Fill in bracketed sections with
> your organization's specific details.

## Document Control

| Field | Value |
|-------|-------|
| **Policy Name** | Data Backup and Recovery Policy |
| **Version** | 1.0 |
| **Effective Date** | [YYYY-MM-DD] |
| **Last Reviewed** | [YYYY-MM-DD] |
| **Next Review** | [YYYY-MM-DD] |
| **Owner** | [VP Engineering / CTO] |
| **Approved By** | [Name, Title] |
| **Classification** | Internal |

---

## 1. Purpose

This policy establishes requirements for backing up [Organization Name]'s data and systems
to protect against data loss, ensure business continuity, and meet regulatory obligations.

## 2. Scope

This policy applies to:
- All production systems and databases
- All environments containing customer data or PII
- Infrastructure configuration and secrets
- Source code repositories and CI/CD state
- [Additional scope items]

This policy does NOT apply to:
- Local developer workstations (covered by endpoint policy)
- Ephemeral test environments with no persistent data
- [Exclusions]

## 3. Roles and Responsibilities

| Role | Responsibilities |
|------|-----------------|
| **Data Owner** (Service Team) | Classify data, define RPO/RTO, validate restores |
| **Backup Administrator** (Platform/SRE) | Implement and monitor backup jobs, manage storage |
| **Security Team** | Audit backup access controls, review encryption |
| **Compliance Officer** | Verify policy adherence, audit evidence collection |
| **Incident Commander** | Authorize DR activation during incidents |

## 4. Data Classification and Backup Tiers

### 4.1 Classification

| Classification | Description | Examples |
|---------------|-------------|----------|
| **Critical** | Data loss causes immediate revenue/compliance impact | Payment data, user accounts, PHI |
| **Important** | Data loss causes significant operational impact | Product catalog, order history |
| **Standard** | Data loss causes inconvenience, recoverable | Logs, analytics, caches |
| **Non-Essential** | Data is easily regenerated | Build artifacts, temp files |

### 4.2 Backup Tiers

| Tier | RPO | RTO | Backup Frequency | Retention | Applicable Classification |
|------|-----|-----|-------------------|-----------|--------------------------|
| 1 | <15 min | <1 hr | Continuous (WAL/replication) | 90 days + 1yr monthly + 7yr yearly | Critical |
| 2 | <1 hr | <4 hr | Hourly | 30 days + 6mo monthly | Important |
| 3 | <4 hr | <8 hr | Every 4 hours | 14 days + 3mo monthly | Standard |
| 4 | <24 hr | <24 hr | Daily | 7 days + 1mo monthly | Non-Essential |

## 5. Backup Requirements

### 5.1 3-2-1-1-0 Rule

All backups must follow the 3-2-1-1-0 rule:
- **3** copies of data (primary + 2 backups)
- **2** different storage media/services
- **1** offsite/cross-region copy
- **1** immutable/air-gapped copy
- **0** errors (verified restores)

### 5.2 Encryption

- All backups must be encrypted at rest using AES-256 or equivalent
- All backup transfers must use encrypted transport (TLS 1.2+, SSH)
- Encryption keys must be stored separately from backup data
- Key rotation must occur at least [annually / per policy]

### 5.3 Access Control

- Backup systems require role-based access control (RBAC)
- No shared credentials for backup operations
- Backup restore operations require approval for Tier 1 systems
- All backup access is logged and auditable

### 5.4 Immutability

- Tier 1 backups must use immutable storage (S3 Object Lock / WORM)
- Immutable retention period: minimum [30/60/90] days
- Deletion of immutable backups requires [VP Engineering] approval

## 6. Backup Verification and Testing

### 6.1 Automated Verification

| Check | Frequency | Method |
|-------|-----------|--------|
| Backup completion | Every backup | Monitoring/alerting |
| Repository integrity | Weekly | `restic check` / `borg check` |
| Restore to test environment | Weekly | Automated restore script |
| Data validation (row counts) | Weekly | Comparison with backup metadata |
| Full DR failover test | [Semi-annually] | DR runbook execution |

### 6.2 Restore Testing

- Tier 1: Weekly automated restore test with data validation
- Tier 2: Monthly automated restore test
- Tier 3-4: Quarterly manual restore test
- All restore tests must be documented with results

### 6.3 DR Testing

- Full DR failover test at least [semi-annually]
- Tabletop exercises at least [quarterly]
- Test results documented and reviewed by management
- Findings tracked to resolution

## 7. Retention Schedule

| Data Type | Minimum Retention | Regulatory Basis |
|-----------|-------------------|-----------------|
| Financial records | 7 years | SOX, Tax regulations |
| Health records (PHI) | 6 years | HIPAA |
| Customer PII | [per privacy policy] | GDPR, CCPA |
| System logs | 1 year | SOC 2 |
| Audit logs | 3 years | SOC 2 |
| General business data | [per classification] | Business policy |

## 8. Monitoring and Alerting

### 8.1 Required Alerts

| Alert | Threshold | Severity | Response |
|-------|-----------|----------|----------|
| Backup failed | Any failure | Critical | Investigate within 1 hour |
| Backup stale | >1.5× scheduled interval | Warning | Investigate within 4 hours |
| Backup missing | >2× scheduled interval | Critical | Investigate immediately |
| Storage >80% | 80% utilization | Warning | Plan capacity expansion |
| Storage >90% | 90% utilization | Critical | Emergency cleanup/expansion |
| Integrity check failed | Any failure | Critical | Investigate immediately |
| Restore test failed | Any failure | Critical | Investigate within 1 hour |

### 8.2 Reporting

- Monthly backup compliance report to [management/compliance team]
- Quarterly backup metrics review
- Annual backup policy review and update

## 9. Incident Response

### 9.1 Data Loss Incident

1. Declare incident per incident management policy
2. Assess scope and impact
3. Identify appropriate backup for recovery
4. Execute restore per DR runbook
5. Validate restored data
6. Document incident and conduct post-mortem

### 9.2 Backup System Failure

1. Alert backup administrator immediately
2. Assess duration of backup gap
3. Implement temporary backup measures if gap >1 RPO period
4. Repair backup system
5. Execute catch-up backup
6. Verify backup continuity

## 10. Compliance Mapping

| Requirement | SOC 2 | HIPAA | GDPR | PCI DSS |
|-------------|-------|-------|------|---------|
| Backup procedures documented | A1.2 | §164.308(a)(7) | Art. 32 | Req. 9.5 |
| Encryption at rest | CC6.1 | §164.312(a)(2)(iv) | Art. 32 | Req. 3.4 |
| Access controls | CC6.1 | §164.312(a)(1) | Art. 32 | Req. 7.1 |
| Regular testing | A1.3 | §164.308(a)(7)(ii)(D) | Art. 32 | Req. 11.5 |
| Audit logging | CC7.2 | §164.312(b) | Art. 30 | Req. 10.2 |
| DR plan | A1.2 | §164.308(a)(7)(ii)(B) | Art. 32 | Req. 12.10 |

## 11. Exceptions

Exceptions to this policy require:
- Written justification
- Risk assessment
- Approval by [policy owner]
- Time-limited exception with review date
- Compensating controls documented

## 12. Policy Violations

Violations of this policy may result in:
- Mandatory remediation with defined timeline
- Escalation to management
- Disciplinary action per HR policy
- Regulatory notification if required

---

**Revision History**

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | [YYYY-MM-DD] | [Author] | Initial policy |
