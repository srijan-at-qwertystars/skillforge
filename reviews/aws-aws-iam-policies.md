# Review: aws-iam-policies

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5

Issues: Non-standard description format (positive:/negative: sub-keys).

Outstanding IAM reference. Covers principals (root/users/roles/groups/federated), policy evaluation logic (5-step), policy language (Effect/Action/Resource/Condition/Principal/NotAction/NotResource), policy types (identity-based managed/customer/inline, resource-based, SCPs, permission boundaries, session policies), IAM Access Analyzer (policy generation, unused access, validation), condition keys (global, ABAC tag-based, operators), cross-account access (role assumption, ExternalId confused deputy, org-wide, org paths), IAM roles for services (EC2 instance profiles + IMDSv2, Lambda execution roles, ECS task/execution roles), OIDC federation (GitHub Actions trust policy, EKS IRSA + Pod Identity), IAM Identity Center (permission sets, ABAC with IdP attributes), SCPs (region restriction with NotAction, protect security services, design rules), permission boundaries (delegation pattern), policy troubleshooting (simulate-principal-policy, CloudTrail, Access Advisor, 6 common denial causes), security patterns (MFA enforcement, root protection, key rotation), and anti-patterns table.
